{-# OPTIONS_GHC -ddump-splices -ddump-to-file #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiWayIf #-}
-- | Architecture-independent translation of semmc semantics (via SimpleBuilder)
-- into macaw IR.
--
-- The main entry point is 'genExecInstruction', which is customized for
-- architecture-specific backends via some parameters.
--
-- The other functions exposed by this module are useful for implementing
-- architecture-specific translations.

module Data.Macaw.SemMC.TH (
  genExecInstruction,
  genExecInstructionLogStdErr,
  genExecInstructionLogging,
  addEltTH,
  appToExprTH,
  evalNonceAppTH,
  evalBoundVar,
  natReprTH,
  floatInfoTH,
  floatInfoFromPrecisionTH,
  symFnName,
  asName
  ) where

import           GHC.TypeLits ( Symbol )
import qualified Data.ByteString as BS

import           Control.Lens ( (^.) )
import           Control.Monad (void)
import qualified Control.Concurrent.Async as Async
import qualified Data.Functor.Const as C
import           Data.Functor.Product
import qualified Data.Foldable as F
import qualified Data.List as L
import qualified Data.Map as Map
import           Data.Maybe ( fromMaybe )
import           Data.Proxy ( Proxy(..) )
import           Data.Semigroup ((<>))
import qualified Data.Text as T
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import           Text.Read ( readMaybe )

import           Data.Parameterized.Classes
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.HasRepr as HR
import qualified Data.Parameterized.Lift as LF
import qualified Data.Parameterized.List as SL
import qualified Data.Parameterized.Map as MapF
import qualified Data.Parameterized.NatRepr as NR
import qualified Data.Parameterized.Nonce as PN
import qualified Data.Parameterized.Pair as Pair
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableFC as FC
import qualified Lang.Crucible.Backend.Simple as S
import qualified What4.BaseTypes as CT
import qualified What4.Expr.BoolMap as BooM
import qualified What4.Expr.Builder as S
import qualified What4.Expr.WeightedSum as WSum
import qualified What4.Interface as SI
import qualified What4.InterpretedFloatingPoint as SI
import qualified What4.SemiRing as SR
import qualified What4.Symbol as Sy

import qualified Dismantle.Instruction as D
import qualified Dismantle.Tablegen.TH.Capture as DT

import qualified SemMC.BoundVar as BV
import           SemMC.Formula
import qualified SemMC.Architecture as A
import qualified SemMC.Architecture.Location as L
import qualified SemMC.Util as U
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.Types as M
import qualified Data.Macaw.Symbolic as M

import Data.Parameterized.NatRepr ( knownNat
                                  , intValue
                                  , natValue
                                  )

import qualified Data.Macaw.SemMC.Generator as G
import qualified Data.Macaw.SemMC.Operands as O
import qualified Data.Macaw.SemMC.Translations as TR
import           Data.Macaw.SemMC.TH.Monad

type Sym t fs = S.SimpleBackend t fs

-- | Generate the top-level lambda with a case expression over an instruction
-- (casing on opcode)
--
-- > \ipVar (Instruction opcode operandList) ->
-- >   case opcode of
-- >     ${CASES}
--
-- where each case in ${CASES} is defined by 'mkSemanticsCase'; each case
-- matches one opcode.
instructionMatcher :: (OrdF a, LF.LiftF a, A.Architecture arch)
                   => (forall tp . L.Location arch tp -> Q Exp)
                   -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -> Library (Sym t fs)
                   -> Name
                   -- ^ The name of the architecture-specific instruction
                   -- matcher to run before falling back to the generic one
                   -> MapF.MapF a (Product (ParameterizedFormula (Sym t fs) arch) (DT.CaptureInfo a))
                   -> (Q Type, Q Type)
                   -> M.Endianness
                   -> Q (Exp, [Dec])
instructionMatcher ltr ena ae lib archSpecificMatcher formulas operandResultType endianness = do
  ipVarName <- newName "_ipVal"
  opcodeVar <- newName "opcode"
  operandListVar <- newName "operands"
  (libDefs, df) <- libraryDefinitions ltr ena ae (snd operandResultType) lib endianness
  (normalCases, bodyDefs) <- unzip <$> mapM (mkSemanticsCase ltr ena ae df ipVarName operandListVar operandResultType endianness) (MapF.toList formulas)
  (fallthruNm, unimp) <- unimplementedInstruction
  fallthroughCase <- match wildP (normalB (appE (varE fallthruNm) (varE opcodeVar))) []
  let allCases :: [Match]
      allCases = concat [ normalCases
                        , [fallthroughCase]
                        ]
  instrVar <- newName "i"
  instrArg <- asP instrVar [p| D.Instruction $(varP opcodeVar) $(varP operandListVar) |]
  matcherRes <- appE (varE archSpecificMatcher) (varE instrVar)
  actionVar <- newName "action"
  let fullDefs = libDefs ++ concatMap (\(t,i) -> [t,i]) bodyDefs
  let instrCase = LetE [unimp] $ CaseE (VarE opcodeVar) allCases
  let lam = LamE [(VarP ipVarName), instrArg] $
         CaseE matcherRes
                   [ Match (ConP 'Just [VarP actionVar])
                               (NormalB $ AppE (ConE 'Just) (VarE actionVar)) []
                   , Match (ConP 'Nothing [])
                               (NormalB instrCase) []
                   ]
  return (lam, fullDefs)

-- | Unimplemented instructions return Nothing here, which will be translated
-- into a TranslationError inside the generator.
unimplementedInstruction :: Q (Name, Dec)
unimplementedInstruction = do
    fname <- newName "noMatch"
    arg1Nm <- newName "unknownOpcode"
    fdecl <- funD fname [clause [varP arg1Nm] (normalB [| Nothing |]) []]
    return (fname, fdecl)


-- | Create a function declaration for each function in the library.
-- Generates the declarations and a lookup function to use to generate
-- calls.
libraryDefinitions :: forall arch t fs . A.Architecture arch
                   => (forall tp . L.Location arch tp -> Q Exp)
                   -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -> Q Type
                   -> Library (Sym t fs)
                   -> M.Endianness
                   -> Q ([Dec], String -> Maybe (MacawQ arch t fs Exp))
libraryDefinitions ltr ena ae archType lib endianness = do
  -- First, construct map for all function names
  let ffs = MapF.elems lib
  varMap :: Map.Map String Name <- Map.fromList <$> traverse fnName ffs

  -- Create lookup functions for names and calls
  let lookupVarName name = Map.lookup name varMap
      lookupCall name = (liftQ . varE) <$> lookupVarName name
  decs <- traverse (translate lookupVarName lookupCall) (MapF.elems lib)
  return (concat decs, lookupCall)
  where
    fnName :: Some (FunctionFormula (Sym t fs)) -> Q (String, Name)
    fnName (Some (FunctionFormula { ffName = name })) = do
      var <- newName ("_df_" ++ name)
      return (name, var)

    translate :: (String -> Maybe Name)
              -> (String -> Maybe (MacawQ arch t fs Exp))
              -> Some (FunctionFormula (Sym t fs))
              -> Q [Dec]
    translate lookupVarName lookupCall (Some ff@(FunctionFormula {})) = do
      (_var, sig, def) <- translateFunction ltr ena ae lookupVarName lookupCall archType ff endianness
      return [sig, def]

-- | Generate a single case for one opcode of the case expression.
-- Generates two parts: the case match, which calls a function to
-- handle the match, and the function definition for handling the
-- match (inlining the function body would create a more complicated
-- case expression which makes GHC much slower).
--
-- > ADD4 -> bodyfun operands
-- >
-- > bodyfun operands = ${BODY}
--
-- where the ${BODY} is generated by 'mkOperandListCase'
mkSemanticsCase :: (LF.LiftF a, A.Architecture arch)
                => (forall tp . L.Location arch tp -> Q Exp)
                -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                -> (String -> Maybe (MacawQ arch t fs Exp))
                -> Name
                -> Name
                -> (Q Type, Q Type)
                -> M.Endianness
                -> MapF.Pair a (Product (ParameterizedFormula (Sym t fs) arch) (DT.CaptureInfo a))
                -> Q (Match, (Dec, Dec))
mkSemanticsCase ltr ena ae df ipVarName operandListVar operandResultType endianness (MapF.Pair opc (Pair semantics capInfo)) =
    do arg1Nm <- newName "operands"
       ofname <- newName $ "opc_" <> (filter ((/=) '"') $ nameBase $ DT.capturedOpcodeName capInfo)
       lTypeVar <- newName "l"
       idsTypeVar <- newName "ids"
       sTypeVar <- newName "s"
       ofsig <- sigD ofname [t|   (M.RegisterInfo (M.ArchReg $(snd operandResultType)), U.HasCallStack)
                                  => M.Value $(snd operandResultType) $(varT idsTypeVar) (M.BVType (M.ArchAddrWidth $(snd operandResultType)))
                                  -> SL.List $(fst operandResultType) $(varT lTypeVar)
                                  -> Maybe (G.Generator $(snd operandResultType)
                                                        $(varT idsTypeVar)
                                                        $(varT sTypeVar) ())
                              |]
       ofdef <- funD ofname
                 [clause [varP ipVarName, varP arg1Nm]
                  (normalB (mkOperandListCase ltr ena ae df ipVarName arg1Nm opc semantics capInfo endianness))
                  []]
       mtch <- match (conP (DT.capturedOpcodeName capInfo) []) (normalB (appE (appE (varE ofname) (varE ipVarName)) (varE operandListVar))) []
       return (mtch, (ofsig, ofdef))


-- | For each opcode case, we have a sub-case expression to destructure the
-- operand list into names that we can reference.  This generates an expression
-- of the form:
--
-- > case operandList of
-- >   op1 :> op2 :> op3 :> Nil -> ${BODY}
--
-- where ${BODY} is generated by 'genCaseBody', which references the operand
-- names introduced by this case (e.g., op1, op2, op3).  Those names are pulled
-- from the DT.CaptureInfo, and have been pre-allocated.  See
-- Dismantle.Tablegen.TH.Capture.captureInfo for information on how those names
-- are generated.
--
-- Note that the structure of the operand list is actually a little more
-- complicated than the above.  Each operand actually has an additional level of
-- wrapper around it, and really looks like:
--
-- >    Dismantle.PPC.ADD4
-- >      -> case operands_ayaa of {
-- >           (Gprc gprc0 :> (Gprc gprc1 :> (Gprc gprc2 :> Nil)))
-- >             -> ${BODY}
--
-- in an example with three general purpose register operands.
mkOperandListCase :: (A.Architecture arch)
                  => (forall tp0 . L.Location arch tp0 -> Q Exp)
                  -> (forall tp0 . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp0 -> Maybe (MacawQ arch t fs Exp))
                  -> (forall tp0 . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp0 -> Maybe (MacawQ arch t fs Exp))
                  -> (String -> Maybe (MacawQ arch t fs Exp))
                  -> Name
                  -> Name
                  -> a tp
                  -> ParameterizedFormula (Sym t fs) arch tp
                  -> DT.CaptureInfo a tp
                  -> M.Endianness
                  -> Q Exp
mkOperandListCase ltr ena ae df ipVarName operandListVar opc semantics capInfo endianness = do
  body <- genCaseBody ltr ena ae df ipVarName opc semantics (DT.capturedOperandNames capInfo) endianness
  DT.genCase capInfo operandListVar body

-- | This is the function that translates formulas (semantics) into expressions
-- that construct macaw terms.
--
-- The stub implementation is essentially
--
-- > undefined ipVar arg1 arg2
--
-- to avoid unused variable warnings.
--
-- The two maps (locVars and opVars) are crucial for translating parameterized
-- formulas into expressions.
genCaseBody :: forall a sh t fs arch
             . (A.Architecture arch)
            => (forall tp . L.Location arch tp -> Q Exp)
            -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
            -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
            -> (String -> Maybe (MacawQ arch t fs Exp))
            -> Name
            -> a sh
            -> ParameterizedFormula (Sym t fs) arch sh
            -> SL.List (C.Const Name) sh
            -> M.Endianness
            -> Q Exp
genCaseBody ltr ena ae df ipVarName _opc semantics varNames endianness = do
  regsName <- newName "_regs"
  translateFormula ltr ena ae df ipVarName semantics (BoundVarInterpretations locVarsMap opVarsMap argVarsMap regsName) varNames endianness
  where
    locVarsMap :: MapF.MapF (SI.BoundVar (Sym t fs)) (L.Location arch)
    locVarsMap = MapF.foldrWithKey (collectVarForLocation (Proxy @arch)) MapF.empty (pfLiteralVars semantics)

    opVarsMap :: MapF.MapF (SI.BoundVar (Sym t fs)) (C.Const Name)
    opVarsMap = SL.ifoldr (collectOperandVars varNames) MapF.empty (pfOperandVars semantics)

    argVarsMap :: MapF.MapF (SI.BoundVar (Sym t fs)) (C.Const Name)
    argVarsMap = MapF.empty

collectVarForLocation :: forall tp arch proxy t fs
                       . proxy arch
                      -> L.Location arch tp
                      -> SI.BoundVar (Sym t fs) tp
                      -> MapF.MapF (SI.BoundVar (Sym t fs)) (L.Location arch)
                      -> MapF.MapF (SI.BoundVar (Sym t fs)) (L.Location arch)
collectVarForLocation _ loc bv = MapF.insert bv loc

-- | Index variables that map to operands
--
-- We record the TH 'Name' for the 'SI.BoundVar' that stands in for each
-- operand.  The idea will be that we will look up bound variables in this map
-- to be able to compute a TH expression to refer to it.
--
-- We have to unwrap and rewrap the 'C.Const' because the type parameter
-- changes when we switch from 'BV.BoundVar' to 'SI.BoundVar'.  See the
-- SemMC.BoundVar module for information about the nature of that change
-- (basically, from 'Symbol' to BaseType).
collectOperandVars :: forall sh tp arch t fs
                    . SL.List (C.Const Name) sh
                   -> SL.Index sh tp
                   -> BV.BoundVar (Sym t fs) arch tp
                   -> MapF.MapF (SI.BoundVar (Sym t fs)) (C.Const Name)
                   -> MapF.MapF (SI.BoundVar (Sym t fs)) (C.Const Name)
collectOperandVars varNames ix (BV.BoundVar bv) m =
  case varNames SL.!! ix of
    C.Const name -> MapF.insert bv (C.Const name) m
{-
     genExecInstruction :: forall k arch (a :: [k] -> *) (proxy :: *
                                                                        -> *).
                                (A.Architecture arch, OrdF a, ShowF a, LF.LiftF a) =>
                                proxy arch
                                -> (forall (tp :: CT.BaseType). L.Location arch tp -> Q Exp)
                                -> (forall (tp :: CT.BaseType) t.

-}
-- | Wrapper for 'genExecInstructionLogging' which generates a no-op
-- LogCfg to disable any logging during the generation.
genExecInstruction :: forall arch (a :: [Symbol] -> *) (proxy :: * -> *)
                    . (A.Architecture arch,
                       HR.HasRepr a (A.ShapeRepr arch),
                       OrdF a,
                       ShowF a,
                       LF.LiftF a)
                   => proxy arch
                   -> (forall tp . L.Location arch tp -> Q Exp)
                   -- ^ A translation of 'L.Location' references into 'Exp's
                   -- that generate macaw IR to reference those expressions
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ A translation of uninterpreted functions into macaw IR;
                   -- returns 'Nothing' if the handler does not know how to
                   -- translate the 'S.NonceApp'.
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ Similarly, a translator for 'S.App's; mostly intended to
                   -- translate division operations into architecture-specific
                   -- statements, which have no representation in macaw.
                   -> Name
                   -- ^ The arch-specific instruction matcher for translating
                   -- instructions directly into macaw IR; this is usually used
                   -- for translating trap and system call type instructions.
                   -- This has to be specified by 'Name' instead of as a normal
                   -- function, as the type would actually refer to types that
                   -- we cannot mention in this shared code (i.e.,
                   -- architecture-specific instruction types).
                   -> [(Some a, BS.ByteString)]
                   -- ^ A list of opcodes (with constraint information
                   -- witnessed) paired with the bytestrings containing their
                   -- semantics.  This comes from semmc.
                   -> [Some (DT.CaptureInfo a)]
                   -- ^ Extra information for each opcode to let us generate
                   -- some TH to match them.  This comes from the semantics
                   -- definitions in semmc.
                   -> [(String, BS.ByteString)]
                   -- ^ A list of defined function names paired with the
                   -- bytestrings containing their definitions.
                   -> (Q Type, Q Type)
                   -> M.Endianness
                   -> Q Exp
genExecInstruction _ ltr ena ae archInsnMatcher semantics captureInfo functions operandResultType endianness = do
  logCfg <- runIO $ U.mkNonLogCfg
  (r, decs) <- genExecInstructionLogging (Proxy @arch) ltr ena ae archInsnMatcher semantics captureInfo functions operandResultType logCfg endianness
  runIO $ U.logEndWith logCfg
  addTopDecls decs
  return r

-- | Wrapper for 'genExecInstructionLogging' which generates a no-op
-- LogCfg to disable any logging during the generation.
genExecInstructionLogStdErr :: forall arch (a :: [Symbol] -> *) (proxy :: * -> *)
                    . (A.Architecture arch,
                       HR.HasRepr a (A.ShapeRepr arch),
                       OrdF a,
                       ShowF a,
                       LF.LiftF a)
                   => proxy arch
                   -> (forall tp . L.Location arch tp -> Q Exp)
                   -- ^ A translation of 'L.Location' references into 'Exp's
                   -- that generate macaw IR to reference those expressions
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ A translation of uninterpreted functions into macaw IR;
                   -- returns 'Nothing' if the handler does not know how to
                   -- translate the 'S.NonceApp'.
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ Similarly, a translator for 'S.App's; mostly intended to
                   -- translate division operations into architecture-specific
                   -- statements, which have no representation in macaw.
                   -> Name
                   -- ^ The arch-specific instruction matcher for translating
                   -- instructions directly into macaw IR; this is usually used
                   -- for translating trap and system call type instructions.
                   -- This has to be specified by 'Name' instead of as a normal
                   -- function, as the type would actually refer to types that
                   -- we cannot mention in this shared code (i.e.,
                   -- architecture-specific instruction types).
                   -> [(Some a, BS.ByteString)]
                   -- ^ A list of opcodes (with constraint information
                   -- witnessed) paired with the bytestrings containing their
                   -- semantics.  This comes from semmc.
                   -> [Some (DT.CaptureInfo a)]
                   -- ^ Extra information for each opcode to let us generate
                   -- some TH to match them.  This comes from the semantics
                   -- definitions in semmc.
                   -> [(String, BS.ByteString)]
                   -- ^ A list of defined function names paired with the
                   -- bytestrings containing their definitions.
                   -> (Q Type, Q Type)
                   -> M.Endianness
                   -> Q Exp
genExecInstructionLogStdErr _ ltr ena ae archInsnMatcher semantics captureInfo functions operandResultType endianness = do
  logCfg <- runIO $ U.mkLogCfg "genExecInstruction"
  logThread <- runIO $ U.asyncLinked (U.stdErrLogEventConsumer (const True) logCfg)
  (r, decs) <- genExecInstructionLogging (Proxy @arch) ltr ena ae archInsnMatcher semantics captureInfo functions operandResultType logCfg endianness
  runIO $ U.logEndWith logCfg
  runIO $ Async.wait logThread
  addTopDecls decs
  return r

-- | Generate an implementation of 'execInstruction' that runs in the
-- 'G.Generator' monad.  We pass in both the original list of semantics files
-- along with the list of opcode info objects.  We can match them up using
-- equality on opcodes (via a MapF).  Generating a combined list up-front would
-- be ideal, but is difficult for various TH reasons (we can't call 'lift' on
-- all of the things we would need to for that).
--
-- The structure of the term produced is documented in 'instructionMatcher'
genExecInstructionLogging :: forall arch (a :: [Symbol] -> *) (proxy :: * -> *)
                             . (A.Architecture arch,
                                HR.HasRepr a (A.ShapeRepr arch),
                                OrdF a,
                                ShowF a,
                                LF.LiftF a)
                   => proxy arch
                   -> (forall tp . L.Location arch tp -> Q Exp)
                   -- ^ A translation of 'L.Location' references into 'Exp's
                   -- that generate macaw IR to reference those expressions
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ A translation of uninterpreted functions into macaw IR;
                   -- returns 'Nothing' if the handler does not know how to
                   -- translate the 'S.NonceApp'.
                   -> (forall tp t fs . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                   -- ^ Similarly, a translator for 'S.App's; mostly intended to
                   -- translate division operations into architecture-specific
                   -- statements, which have no representation in macaw.
                   -> Name
                   -- ^ The arch-specific instruction matcher for translating
                   -- instructions directly into macaw IR; this is usually used
                   -- for translating trap and system call type instructions.
                   -- This has to be specified by 'Name' instead of as a normal
                   -- function, as the type would actually refer to types that
                   -- we cannot mention in this shared code (i.e.,
                   -- architecture-specific instruction types).
                   -> [(Some a, BS.ByteString)]
                   -- ^ A list of opcodes (with constraint information
                   -- witnessed) paired with the bytestrings containing their
                   -- semantics.  This comes from semmc.
                   -> [Some (DT.CaptureInfo a)]
                   -- ^ Extra information for each opcode to let us generate
                   -- some TH to match them.  This comes from the semantics
                   -- definitions in semmc.
                   -> [(String, BS.ByteString)]
                   -- ^ A list of defined function names paired with the
                   -- bytestrings containing their definitions.
                   -> (Q Type, Q Type)
                   -> U.LogCfg
                   -- ^ Logging configuration (explicit rather than
                   -- the typical implicit expression because I don't
                   -- know how to pass implicits to TH splices
                   -- invocations.
                   -> M.Endianness
                   -- ^ Endianness for this instruction set.
                   -> Q (Exp, [Dec])
genExecInstructionLogging _ ltr ena ae archInsnMatcher semantics captureInfo functions operandResultType logcfg endianness =
    U.withLogCfg logcfg $ do
      Some ng <- runIO PN.newIONonceGenerator
      sym <- runIO (S.newSimpleBackend S.FloatIEEERepr ng)
      runIO (S.startCaching sym)
      env <- runIO (formulaEnv (Proxy @arch) sym)
      lib <- runIO (loadLibrary (Proxy @arch) sym env functions)
      formulas <- runIO (loadFormulas sym env lib semantics)
      let formulasWithInfo = foldr (attachInfo formulas) MapF.empty captureInfo
      instructionMatcher ltr ena ae lib archInsnMatcher formulasWithInfo operandResultType endianness
        where
          attachInfo m0 (Some ci) m =
              let co = DT.capturedOpcode ci
              in case MapF.lookup co m0 of
                   Nothing -> m
                   Just pf -> MapF.insert co (Pair pf ci) m

natReprTH :: M.NatRepr w -> Q Exp
natReprTH w = [| knownNat :: M.NatRepr $(litT (numTyLit (intValue w))) |]

natReprFromIntTH :: Int -> Q Exp
natReprFromIntTH i = [| knownNat :: M.NatRepr $(litT (numTyLit (fromIntegral i))) |]

floatInfoTH :: M.FloatInfoRepr fi -> Q Exp
floatInfoTH fi = [| fi |]

floatInfoFromPrecisionTH :: CT.FloatPrecisionRepr fpp -> Q Exp
floatInfoFromPrecisionTH =
  floatInfoTH . M.floatInfoFromCrucible . SI.floatPrecisionToInfoRepr

-- | Sequence a list of monadic actions without constructing an intermediate
-- list structure
doSequenceQ :: [StmtQ] -> [Stmt] -> Q Exp
doSequenceQ stmts body = doE (stmts ++ map return body)

translateFormula :: forall arch t fs sh .
                    (A.Architecture arch)
                 => (forall tp . L.Location arch tp -> Q Exp)
                 -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                 -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                 -> (String -> Maybe (MacawQ arch t fs Exp))
                 -> Name
                 -> ParameterizedFormula (Sym t fs) arch sh
                 -> BoundVarInterpretations arch t fs
                 -> SL.List (C.Const Name) sh
                 -> M.Endianness
                 -> Q Exp
translateFormula ltr ena ae df ipVarName semantics interps varNames endianness = do
  let preamble = [ bindS (varP (regsValName interps)) [| G.getRegs |] ]
  exps <- runMacawQ ltr ena ae df (mapM_ translateDefinition (MapF.toList (pfDefs semantics)))
  -- In the event that we have an empty list of expressions, insert a
  -- final return ()
  final <- NoBindS <$> [| return () |]
  let allExps = case exps of
        [] -> [final]
        _ -> exps
  [| Just $(doSequenceQ preamble allExps) |]
  where translateDefinition :: MapF.Pair (Parameter arch sh) (S.SymExpr (Sym t fs))
                            -> MacawQ arch t fs ()
        translateDefinition (MapF.Pair param expr) = do
          case param of
            OperandParameter _w idx -> do
              let C.Const name = varNames SL.!! idx
              newVal <- addEltTH endianness interps expr
              appendStmt [| G.setRegVal (O.toRegister $(varE name)) $(return newVal) |]
            LiteralParameter loc
              -- FIXME: The below case is necessary for calls to
              -- defined functions that write to memory, but we end up
              -- calling locToRegTH on the memory object, which is a
              -- problem.
              -- -- | L.isMemoryLocation loc
              -- -- , S.NonceAppExpr n <- expr
              -- -- , S.FnApp symFn args <- S.nonceExprApp n
              -- -- , S.DefinedFnInfo {} <- S.symFnInfo symFn -> do
              -- --   let fnName = symFnName symFn
              -- --   funMaybe <- definedFunction fnName
              -- --   case funMaybe of
              -- --     Just fun -> do
              -- --       argExprs <- sequence $ FC.toListFC (addEltTH endianness interps) args
              -- --       return ()
              -- --       -- return $ foldl AppE fun argExprs
              -- --     Nothing -> fail ("Unknown defined function: " ++ fnName)
              | L.isMemoryLocation loc
              , S.NonceAppExpr n <- expr
              -> do
                  mtranslator <- withNonceAppEvaluator $ \evalNonceApp ->
                    return (evalNonceApp interps (S.nonceExprApp n))
                  case mtranslator of
                    Just translator -> do
                      _mem <- translator
                      appendStmt [| return () |]
                    _ | S.FnApp symFn args <- S.nonceExprApp n
                      , Just _ <- matchWriteMemWidth (symFnName symFn)
                      -> void $ writeMemTH interps symFn args endianness
                    _ -> error "translateDefinition: unexpected memory write"

              -- -- | L.isMemoryLocation loc
              -- -- , S.BoundVarExpr bVar <- expr
              -- -- , Just loc <- MapF.lookup bVar (locVars interps) -> withLocToReg $ \ltr -> do
              -- --     return ()
              -- --     -- appendStmt [| error "BOUND VAR MEM" |]
              -- --     -- bindExpr expr [| return ($(varE (regsValName interps)) ^. M.boundValue $(ltr loc)) |]
              -- -- | L.isMemoryLocation loc
              -- -- , S.BoundVarExpr bVar <- expr -> do
              -- --     return ()
              -- --     -- , Nothing <- MapF.lookup bVar (locVars interps) -> withLocToReg $ \ltr -> do
              -- --     -- appendStmt [| error $(return $ LitE (StringL ("BAD BOUND VAR MEM: " <> show bVar))) |]
              -- -- | L.isMemoryLocation loc
              -- -- , S.AppExpr _ <- expr -> do
              -- --     error $ "WRITE TO MEM: APP"


              | otherwise -> do
                  valExp <- addEltTH endianness interps expr
                  appendStmt [| G.setRegVal $(ltr loc) $(return valExp) |]
            FunctionParameter str (WrappedOperand _ opIx) _w -> do
              let C.Const boundOperandName = varNames SL.!! opIx
              case lookup str (A.locationFuncInterpretation (Proxy @arch)) of
                Nothing -> fail ("Function has no definition: " ++ str)
                Just fi -> do
                  valExp <- addEltTH endianness interps expr
                  appendStmt [| case $(varE (A.exprInterpName fi)) $(varE boundOperandName) of
                                   Just reg -> G.setRegVal (O.toRegister reg) $(return valExp)
                                   Nothing -> fail ("Invalid instruction form at " ++ show $(varE ipVarName) ++ " in " ++ $(litE (stringL str)))
                               |]

translateFunction :: forall arch t fs args ret .
                     (A.Architecture arch)
                  => (forall tp . L.Location arch tp -> Q Exp)
                  -> (forall tp . BoundVarInterpretations arch t fs -> S.NonceApp t (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                  -> (forall tp . BoundVarInterpretations arch t fs -> S.App (S.Expr t) tp -> Maybe (MacawQ arch t fs Exp))
                  -> (String -> Maybe Name)
                  -- ^ names of all functions that we might call
                  -> (String -> Maybe (MacawQ arch t fs Exp))
                  -> Q Type
                  -> FunctionFormula (Sym t fs) '(args, ret)
                  -> M.Endianness
                  -> Q (Name, Dec, Dec)
translateFunction ltr ena ae fnName df archType ff endianness = do
  let funNameErr = error ("Undefined function " ++ ffName ff)
  let var = fromMaybe funNameErr (fnName (ffName ff))
  argVars :: [Name]
    <- sequence $ FC.toListFC (\bv -> newName (bvarName bv)) (ffArgVars ff)
  let argVarMap :: MapF.MapF (SI.BoundVar (Sym t fs)) (C.Const Name)
      argVarMap = MapF.fromList $ zipWith pair bvs argVars
        where
          bvs :: [Some (SI.BoundVar (Sym t fs))]
          bvs = FC.toListFC Some (ffArgVars ff)
          pair (Some bv) v = Pair.Pair bv (C.Const v)
      interps = BoundVarInterpretations { locVars = MapF.empty
                                        , regsValName = mkName "<invalid>"
                                        -- only used for loc vars; we have none
                                        , opVars = MapF.empty
                                        , valVars = argVarMap }
      expr = case S.symFnInfo (ffDef ff) of
        S.DefinedFnInfo _ e _ -> e
        _ -> error $ "expected a defined function; found " ++ show (ffDef ff)
  stmts <- runMacawQ ltr ena ae df $ do
    val <- addEltTH endianness interps expr
    appendStmt [| return $(return val) |]
  idsTy <- varT <$> newName "ids"
  sTy <- varT <$> newName "s"
  let translate :: forall tp. CT.BaseTypeRepr tp -> Q Type
      translate tp =
        [t| M.Value $(archType) $(idsTy) $(translateBaseType tp) |]
      argHsTys = FC.toListFC translate (ffArgTypes ff)
      retHsTy = [t| G.Generator $(archType) $(idsTy) $(sTy)
                     $(translate (ffRetType ff)) |]
      ty = foldr (\a r -> [t| $(a) -> $(r) |]) retHsTy argHsTys
      body = doE (map return stmts)
  sig <- sigD var ty
  def <- funD var [clause (map varP argVars) (normalB body) []]
  return (var, sig, def)

translateBaseType :: CT.BaseTypeRepr tp -> Q Type
translateBaseType tp =
  case tp of
    CT.BaseBoolRepr -> [t| M.BoolType |]
    CT.BaseBVRepr n -> appT [t| M.BVType |] (litT (numTyLit (intValue n)))
    _ -> fail $ "unsupported base type: " ++ show tp

-- | wrapper around bitvector constants that forces some type
-- variables to match those of the monadic context.
genBVValue :: 1 SI.<= w => NR.NatRepr w -> Integer -> G.Generator arch ids s (M.Value arch ids (M.BVType w))
genBVValue repr i = return (M.BVValue repr i)

addEltTH :: forall arch t fs ctp .
            (A.Architecture arch)
         => M.Endianness
         -> BoundVarInterpretations arch t fs
         -> S.Expr t ctp
         -> MacawQ arch t fs Exp
addEltTH endianness interps elt = do
  mexp <- lookupElt elt
  case mexp of
    Just e -> return e
    Nothing ->
      case elt of
        S.AppExpr appElt -> do
          translatedExpr <- appToExprTH endianness (S.appExprApp appElt) interps
          bindExpr elt [| G.addExpr =<< $(return translatedExpr) |]
        S.BoundVarExpr bVar -> do
          translatedBV <- evalBoundVar interps bVar
          bindExpr elt (return translatedBV)
        S.NonceAppExpr n -> do
          translatedExpr <- evalNonceAppTH endianness interps (S.nonceExprApp n)
          bindExpr elt (return translatedExpr)
        S.SemiRingLiteral srTy val _
          | (SR.SemiRingBVRepr _ w) <- srTy ->
            bindExpr elt [| genBVValue $(natReprTH w) $(lift val) |]
          | otherwise -> liftQ [| error "SemiRingLiteral Elts are not supported" |]
        S.StringExpr {} -> liftQ [| error "StringExpr elts are not supported" |]
        S.BoolExpr b _loc -> bindExpr elt [| return (M.BoolValue $(lift b)) |]

evalBoundVar :: forall arch t fs ctp .
                (A.Architecture arch)
             => BoundVarInterpretations arch t fs
             -> S.ExprBoundVar t ctp
             -> MacawQ arch t fs Exp
evalBoundVar interps bVar =
  if | Just loc <- MapF.lookup bVar (locVars interps) -> withLocToReg $ \ltr -> do
       liftQ [| return ($(varE (regsValName interps)) ^. M.boundValue $(ltr loc)) |]
     | Just (C.Const name) <- MapF.lookup bVar (opVars interps) ->
       liftQ [| return $ O.extractValue $(varE (regsValName interps)) $(varE name) |]
     | Just (C.Const name) <- MapF.lookup bVar (valVars interps) ->
       liftQ [| return $(varE name) |]
     | otherwise -> fail $ "bound var not found: " ++ show bVar
  
symFnName :: S.ExprSymFn t args ret -> String
symFnName = T.unpack . Sy.solverSymbolAsText . S.symFnName

bvarName :: S.ExprBoundVar t tp -> String
bvarName = T.unpack . Sy.solverSymbolAsText . S.bvarName

-- | Create Generator code to write a value to memory. We return the
-- argument that represents the memory in case it's needed.
writeMemTH :: forall arch t fs args ret
            . (A.Architecture arch)
           => BoundVarInterpretations arch t fs
           -> S.ExprSymFn t args ret
           -> Ctx.Assignment (S.Expr t) args
           -> M.Endianness
           -> MacawQ arch t fs (Some (S.Expr t))
writeMemTH bvi symFn args endianness =
  case FC.toListFC Some args of
    [Some mem, Some addr, Some val] -> case SI.exprType val of
      SI.BaseBVRepr memWidthRepr -> do
        -- FIXME: we aren't checking that the width is a multiple of 8.
        let memWidth = fromIntegral (intValue memWidthRepr) `div` 8
        addrValExp <- addEltTH endianness bvi addr
        writtenValExp <- addEltTH endianness bvi val
        appendStmt [| G.addStmt (M.WriteMem $(return addrValExp) (M.BVMemRepr $(natReprFromIntTH memWidth) endianness) $(return writtenValExp)) |]
        return (Some mem)
      tp -> fail ("Invalid memory write value type for " <> symFnName symFn <> ": " <> showF tp)
    l -> fail ("Invalid memory write argument list for " <> symFnName symFn <> ": " <> show l)

-- FIXME: Generalize this to take a symFn, checking the name, argument
-- types, and return type (possibly)
-- | Match a "write_mem" intrinsic and return the number of bytes written
matchWriteMemWidth :: String -> Maybe Int
matchWriteMemWidth s = do
  suffix <- L.stripPrefix "uf_write_mem_" s
  (`div` 8) <$> readMaybe suffix

evalNonceAppTH :: forall arch t fs tp
                . (A.Architecture arch)
               => M.Endianness
               -> BoundVarInterpretations arch t fs
               -> S.NonceApp t (S.Expr t) tp
               -> MacawQ arch t fs Exp
evalNonceAppTH endianness bvi nonceApp = do
  mtranslator <- withNonceAppEvaluator $ \evalNonceApp -> return (evalNonceApp bvi nonceApp)
  case mtranslator of
    Just translator -> translator
    Nothing -> defaultNonceAppEvaluator endianness bvi nonceApp

defaultNonceAppEvaluator :: forall arch t fs tp
                          . (A.Architecture arch)
                         => M.Endianness
                         -> BoundVarInterpretations arch t fs
                         -> S.NonceApp t (S.Expr t) tp
                         -> MacawQ arch t fs Exp
defaultNonceAppEvaluator endianness bvi nonceApp =
  case nonceApp of
    S.FnApp symFn args
      | S.DefinedFnInfo {} <- S.symFnInfo symFn -> do
          let fnName = symFnName symFn
          funMaybe <- definedFunction fnName
          case funMaybe of
            Just fun -> do
              argExprs <- sequence $ FC.toListFC (addEltTH endianness bvi) args
              return $ foldl AppE fun argExprs
            Nothing -> fail ("Unknown defined function: " ++ fnName)
      | otherwise -> do
          let fnName = symFnName symFn
              fnArgTypes = S.symFnArgTypes symFn
              fnRetType = S.symFnReturnType symFn
          case fnName of
            -- For count leading zeros, we don't have a SimpleBuilder term to reduce
            -- it to, so we have to manually transform it to macaw here (i.e., we
            -- can't use the more general substitution method, since that is in
            -- terms of rewriting simplebuilder).
            "uf_clz_32" ->
              case FC.toListFC Some args of
                [Some loc] -> do
                  locExp <- addEltTH endianness bvi loc
                  liftQ [| G.addExpr (G.AppExpr (M.Bsr (NR.knownNat @32) $(return locExp))) |]
                _ -> fail ("Unsupported argument list for clz: " ++ showF args)
            "uf_clz_64" ->
              case FC.toListFC Some args of
                [Some loc] -> do
                  locExp <- addEltTH endianness bvi loc
                  liftQ [| G.addExpr (G.AppExpr (M.Bsr (NR.knownNat @64) $(return locExp))) |]
                _ -> fail ("Unsupported argument list for clz: " ++ showF args)
            "uf_popcnt_32" ->
              case FC.toListFC Some args of
                [Some loc] -> do
                  locExp <- addEltTH endianness bvi loc
                  liftQ [| G.addExpr (G.AppExpr (M.PopCount (NR.knownNat @32) $(return locExp))) |]
                _ -> fail ("Unsupported argument list for popcnt: " ++ showF args)
            "uf_popcnt_64" ->
              case FC.toListFC Some args of
                [Some loc] -> do
                  locExp <- addEltTH endianness bvi loc
                  liftQ [| G.addExpr (G.AppExpr (M.PopCount (NR.knownNat @64) $(return locExp))) |]
                _ -> fail ("Unsupported argument list for popcnt: " ++ showF args)
            "uf_undefined" -> do
              case S.nonceAppType nonceApp of
                CT.BaseBVRepr n ->
                  liftQ [| M.AssignedValue <$> G.addAssignment (M.SetUndefined (M.BVTypeRepr $(natReprTH n))) |]
                nt -> fail ("Invalid type for undefined: " ++ show nt)
            _ | Just nBytes <- readMemBytes fnName -> do
                case FC.toListFC Some args of
                  [_, Some addrElt] -> do
                    -- read_mem has a shape such that we expect two arguments; the
                    -- first is just a stand-in in the semantics to represent the
                    -- memory.
                    addr <- addEltTH endianness bvi addrElt
                    liftQ [| let memRep = M.BVMemRepr (NR.knownNat :: NR.NatRepr $(litT (numTyLit (fromIntegral nBytes)))) endianness
                            in M.AssignedValue <$> G.addAssignment (M.ReadMem $(return addr) memRep)
                           |]
                  _ -> fail ("Unexpected arguments to read_mem: " ++ showF args)
              | let interp = A.locationFuncInterpretation (Proxy @arch)
              , Just fi <- lookup fnName interp -> do
                  -- args is an assignment that contains elts; we could just generate
                  -- expressions that evaluate each one and then splat them into new names
                  -- that we apply our name to.
                  case FC.toListFC (asName fnName bvi) args of
                    [] -> fail ("zero-argument uninterpreted functions are not supported: " ++ fnName)
                    argNames -> do
                      let call = appE (varE (A.exprInterpName fi)) $ foldr1 appE (map varE argNames)
                      liftQ [| return $ O.extractValue $(varE (regsValName bvi)) ($(call)) |]
              | Just _ <- matchWriteMemWidth fnName -> do
                Some memExpr <- writeMemTH bvi symFn args endianness
                mem <- addEltTH endianness bvi memExpr
                liftQ [| return $(return mem) |]
              | otherwise -> error $ "Unsupported function: " ++ show fnName ++ "(" ++ show fnArgTypes ++ ") -> " ++ show fnRetType
    _ -> error "Unsupported NonceApp case"

-- | Parse the name of a memory read intrinsic and return the number of bytes
-- that it reads.  For example
--
-- > readMemBytes "read_mem_8" == Just 1
readMemBytes :: String -> Maybe Int
readMemBytes s = do
  nBitsStr <- L.stripPrefix "uf_read_mem_" s
  nBits <- readMaybe nBitsStr
  return (nBits `div` 8)

asName :: String -> BoundVarInterpretations arch t fs -> S.Expr t tp -> Name
asName ufName bvInterps elt =
  case elt of
    S.BoundVarExpr bVar ->
      case MapF.lookup bVar (opVars bvInterps) of
        Nothing -> error ("Expected " ++ show bVar ++ " to have an interpretation")
        Just (C.Const name) -> name
    _ -> error ("Unexpected elt as name (" ++ showF elt ++ ") in " ++ ufName)

appToExprTH :: (A.Architecture arch)
            => M.Endianness
            -> S.App (S.Expr t) tp
            -> BoundVarInterpretations arch t fs
            -> MacawQ arch t fs Exp
appToExprTH endianness app interps = do
  mtranslator <- withAppEvaluator $ \evalApp -> return (evalApp interps app)
  case mtranslator of
    Just translator -> translator
    Nothing -> defaultAppEvaluator endianness app interps

defaultAppEvaluator :: (A.Architecture arch)
                    => M.Endianness
                    -> S.App (S.Expr t) ctp
                    -> BoundVarInterpretations arch t fs
                    -> MacawQ arch t fs Exp
defaultAppEvaluator endianness elt interps = case elt of
  S.NotPred bool -> do
    e <- addEltTH endianness interps bool
    liftQ [| return (G.AppExpr (M.NotApp $(return e))) |]
  S.ConjPred boolmap -> evalBoolMap endianness interps AndOp True boolmap
  S.BaseIte bt _ test t f -> do
    testE <- addEltTH endianness interps test
    tE <- addEltTH endianness interps t
    fE <- addEltTH endianness interps f
    case bt of
      CT.BaseBoolRepr -> liftQ [| return
                                  (G.AppExpr
                                   (M.Mux M.BoolTypeRepr
                                    $(return testE) $(return tE) $(return fE)))
                                |]
      CT.BaseBVRepr w -> liftQ [| return
                                  (G.AppExpr
                                   (M.Mux (M.BVTypeRepr $(natReprTH w))
                                    $(return testE) $(return tE) $(return fE)))
                                |]
      CT.BaseFloatRepr fpp -> liftQ [| return
                                       (G.AppExpr
                                        (M.Mux (M.FloatTypeRepr $(floatInfoFromPrecisionTH fpp))
                                         $(return testE) $(return tE) $(return fE)))
                                     |]
      CT.BaseNatRepr -> liftQ [| error "Macaw semantics for nat ITE unsupported" |]
      CT.BaseIntegerRepr -> liftQ [| error "Macaw semantics for integer ITE unsupported" |]
      CT.BaseRealRepr -> liftQ [| error "Macaw semantics for real ITE unsupported" |]
      CT.BaseStringRepr {} -> liftQ [| error "Macaw semantics for string ITE unsupported" |]
      CT.BaseComplexRepr -> liftQ [| error "Macaw semantics for complex ITE unsupported" |]
      CT.BaseStructRepr {} -> liftQ [| error "Macaw semantics for struct ITE unsupported" |]
      CT.BaseArrayRepr {} -> liftQ [| error "Macaw semantics for array ITE unsupported" |]

  S.BaseEq _bt bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.Eq $(return e1) $(return e2))) |]
  S.BVSlt bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.BVSignedLt $(return e1) $(return e2))) |]
  S.BVUlt bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.BVUnsignedLt $(return e1) $(return e2))) |]
  S.BVConcat w bv1 bv2 -> do
    let u = S.bvWidth bv1
        v = S.bvWidth bv2
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| TR.bvconcat $(return e1) $(return e2) $(natReprTH v) $(natReprTH u) $(natReprTH w) |]
  S.BVSelect idx n bv -> do
    let w = S.bvWidth bv
    case natValue n + 1 <= natValue w of
      True -> do
        e <- addEltTH endianness interps bv
        liftQ [| TR.bvselect $(return e) $(natReprTH n) $(natReprTH idx) $(natReprTH w) |]
      False -> do
        e <- addEltTH endianness interps bv
        liftQ [| case testEquality $(natReprTH n) $(natReprTH w) of
                   Just Refl -> return (G.ValueExpr $(return e))
                   Nothing -> error "Invalid reprs for BVSelect translation"
               |]
  S.BVTestBit idx bv -> do
    bvValExp <- addEltTH endianness interps bv
    liftQ [| G.AppExpr <$> (M.BVTestBit <$>
                            G.addExpr (G.ValueExpr (M.BVValue $(natReprTH (S.bvWidth bv)) $(lift idx))) <*>
                            pure $(return bvValExp)) |]

  S.SemiRingSum sm ->
    case WSum.sumRepr sm of
      SR.SemiRingBVRepr SR.BVArithRepr w ->
        let smul mul e = do y <- addEltTH endianness interps e
                            liftQ [| return
                                     (G.AppExpr
                                      (M.BVMul $(natReprTH w)
                                       (M.BVValue $(natReprTH w) $(lift mul))
                                       $(return y)))
                                   |]
            sval v = liftQ [| return (G.ValueExpr (M.BVValue $(natReprTH w) $(lift v))) |]
            add x y = liftQ [| G.AppExpr <$> (M.BVAdd $(natReprTH w)
                                              <$> (G.addExpr =<< $(return x))
                                              <*> (G.addExpr =<< $(return y)))
                                |]
        in WSum.evalM add smul sval sm
      SR.SemiRingBVRepr SR.BVBitsRepr w ->
        let smul mul e = do y <- addEltTH endianness interps e
                            liftQ [| return
                                     (G.AppExpr
                                      (M.BVAnd $(natReprTH w)
                                       (M.BVValue $(natReprTH w) $(lift mul))
                                       $(return y)))
                                   |]
            sval v = liftQ [| return (G.ValueExpr (M.BVValue $(natReprTH w) $(lift v))) |]
            add x y = liftQ [| G.AppExpr <$> (M.BVXor $(natReprTH w)
                                              <$> (G.addExpr =<< $(return x))
                                              <*> (G.addExpr =<< $(return y)))
                                |]
        in WSum.evalM add smul sval sm
      _ -> liftQ [| error "unsupported SemiRingSum repr for macaw semmc TH" |]

  S.SemiRingProd pd ->
    case WSum.prodRepr pd of
      SR.SemiRingBVRepr SR.BVArithRepr w ->
        let pmul x y = liftQ
                       [| return
                          (G.AppExpr
                           (M.BVMul $(natReprTH w) $(return x) $(return y)))
                        |]
            unit = liftQ [| return $ M.BVValue $(natReprTH w) 1 |]
            convert = addEltTH endianness interps
        in WSum.prodEvalM pmul convert pd >>= maybe unit return
      SR.SemiRingBVRepr SR.BVBitsRepr w ->
        let pmul x y = liftQ
                       [| return
                          (G.AppExpr
                           (M.BVAnd $(natReprTH w) $(return x) $(return y)))
                        |]
            unit = liftQ [| return (M.BVValue $(natReprTH w) $(lift $ SI.maxUnsigned w)) |]
            convert = addEltTH endianness interps
        in WSum.prodEvalM pmul convert pd >>= maybe unit return
      _ -> liftQ [| error "unsupported SemiRingProd repr for macaw semmc TH" |]

  S.BVOrBits w bs -> do
    -- This is a TH Expr that is of type (Macaw) Value at run-time
    zero <- liftQ [| return (G.ValueExpr (M.BVValue $(natReprTH w) 0)) |]
    -- These are all TH Exprs that are of the (Macaw) Value at run-time
    bs' <- mapM (addEltTH endianness interps) (S.bvOrToList bs)
    let por x y = do
          liftQ [|  do y' <- G.addExpr =<< $(return y)
                       return (G.AppExpr (M.BVOr $(natReprTH w) $(return x) y'))
                 |]
    F.foldrM por zero bs'

  S.BVShl w bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.BVShl $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVLshr w bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.BVShr $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVAshr w bv1 bv2 -> do
    e1 <- addEltTH endianness interps bv1
    e2 <- addEltTH endianness interps bv2
    liftQ [| return (G.AppExpr (M.BVSar $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVZext w bv -> do
    e <- addEltTH endianness interps bv
    liftQ [| return (G.AppExpr (M.UExt $(return e) $(natReprTH w))) |]
  S.BVSext w bv -> do
    e <- addEltTH endianness interps bv
    liftQ [| return (G.AppExpr (M.SExt $(return e) $(natReprTH w))) |]

  -- S.StructCtor tps flds -> do
  --   es <- sequence $ FC.toListFC (addEltTH endianness interps) flds
  
  -- S.StructField fld ix ixTp -> error $ "struct fields unsupported"
  _ -> error $ "unsupported Crucible elt: " <> show elt
--  _ -> liftQ [| error $ "unsupported Crucible elt" |]


----------------------------------------------------------------------

data BoolMapOp = AndOp | OrOp


evalBoolMap :: A.Architecture arch =>
               M.Endianness
            -> BoundVarInterpretations arch t fs
            -> BoolMapOp
            -> Bool
            -> BooM.BoolMap (S.Expr t)
            -> MacawQ arch t fs Exp
evalBoolMap endianness interps op defVal bmap =
  case BooM.viewBoolMap bmap of
    BooM.BoolMapUnit ->     liftQ [| return (boolBase $(lift defVal)) |]
    BooM.BoolMapDualUnit -> liftQ [| return (bNotBase $(lift defVal)) |]
    BooM.BoolMapTerms ts ->
         do d <- liftQ [| return (boolBase $(lift defVal)) |]
            F.foldl (joinBool endianness interps op) (return d) ts


boolBase, bNotBase :: A.Architecture arch => Bool -> G.Expr arch t 'M.BoolType
boolBase = G.ValueExpr . M.BoolValue
bNotBase = boolBase . not

joinBool :: A.Architecture arch =>
            M.Endianness
         -> BoundVarInterpretations arch t fs
         -> BoolMapOp
         -> MacawQ arch t fs Exp
         -> (S.Expr t SI.BaseBoolType, S.Polarity)
         -> MacawQ arch t fs Exp
joinBool endianness interps op e r =
  do n <- case r of
            (t, BooM.Positive) -> do p <- addEltTH endianness interps t
                                     liftQ [| return $(return p) |]
            (t, BooM.Negative) -> do p <- addEltTH endianness interps t
                                     liftQ [| (G.addExpr =<< return (G.AppExpr (M.NotApp $(return p)))) |]
     j <- e
     case op of
       AndOp -> liftQ [| G.AppExpr <$> (M.AndApp <$> (G.addExpr =<< $(return j)) <*> $(return n)) |]
       OrOp  -> liftQ [| G.AppExpr <$> (M.OrApp  <$> (G.addExpr =<< $(return j)) <*> $(return n)) |]
