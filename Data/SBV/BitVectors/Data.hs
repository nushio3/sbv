-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.Data
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Internal data-structures for the sbv library
-----------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE PatternGuards              #-}

module Data.SBV.BitVectors.Data
 ( SBool, SWord8, SWord16, SWord32, SWord64
 , SInt8, SInt16, SInt32, SInt64, SInteger
 , SymWord(..)
 , CW(..), cwSameType, cwIsBit, cwToBool
 , mkConstCW ,liftCW2, mapCW, mapCW2
 , SW(..), trueSW, falseSW, trueCW, falseCW
 , SBV(..), NodeId(..), mkSymSBV
 , ArrayContext(..), ArrayInfo, SymArray(..), SFunArray(..), mkSFunArray, SArray(..), arrayUIKind
 , sbvToSW, sbvToSymSW
 , SBVExpr(..), newExpr
 , cache, uncache, uncacheAI, HasSignAndSize(..)
 , Op(..), NamedSymVar, UnintKind(..), getTableIndex, Pgm, Symbolic, runSymbolic, runSymbolic', State, inProofMode, SBVRunMode(..), Size(..), Outputtable(..), Result(..)
 , getTraceInfo, getConstraints, addConstraint
 , SBVType(..), newUninterpreted, unintFnUIKind, addAxiom
 , Quantifier(..), needsExistentials
 , SMTLibPgm(..), SMTLibVersion(..)
 ) where

import Control.DeepSeq                 (NFData(..))
import Control.Monad                   (when)
import Control.Monad.Reader            (MonadReader, ReaderT, ask, runReaderT)
import Control.Monad.Trans             (MonadIO, liftIO)
import Data.Char                       (isAlpha, isAlphaNum)
import Data.Int                        (Int8, Int16, Int32, Int64)
import Data.Word                       (Word8, Word16, Word32, Word64)
import Data.IORef                      (IORef, newIORef, modifyIORef, readIORef, writeIORef)
import Data.List                       (intercalate, sortBy)
import Data.Maybe                      (isJust, fromJust, fromMaybe)

import qualified Data.IntMap   as IMap (IntMap, empty, size, toAscList, lookup, insert, insertWith)
import qualified Data.Map      as Map  (Map, empty, toList, size, insert, lookup)
import qualified Data.Foldable as F    (toList)
import qualified Data.Sequence as S    (Seq, empty, (|>))

import System.Mem.StableName
import System.Random

import Data.SBV.Utils.Lib

-- | 'CW' represents a concrete word of a fixed size:
-- Endianness is mostly irrelevant (see the 'FromBits' class).
-- For signed words, the most significant digit is considered to be the sign.
data CW = CW { cwSigned :: !Bool    -- ^ Is the word signed?
             , cwSize   :: !Size    -- ^ Size of the word (unbounded if Nothing)
             , cwVal    :: !Integer -- ^ The underlying value, represented as a Haskell 'Integer'
             }
        deriving (Eq, Ord)

-- | Are two CW's of the same type?
cwSameType :: CW -> CW -> Bool
cwSameType x y = cwSigned x == cwSigned y && cwSize x == cwSize y

-- | Is this a bit?
cwIsBit :: CW -> Bool
cwIsBit x = not (hasSign x) && not (isInfPrec x) && intSizeOf x == 1

-- | Convert a CW to a Haskell boolean
cwToBool :: CW -> Bool
cwToBool x = cwVal x /= 0

-- | Normalize a CW. Essentially performs modular arithmetic to make sure the
-- value can fit in the given bit-size. Note that this is rather tricky for
-- negative values, due to asymmetry. (i.e., an 8-bit negative number represents
-- values in the range -128 to 127; thus we have to be careful on the negative side.)
normCW :: CW -> CW
normCW x
 | isInfPrec x = x
 | True        = x { cwVal = norm }
 where sz = intSizeOf x
       norm | sz == 0    = 0
            | cwSigned x = let rg = 2 ^ (sz - 1)
                           in case divMod (cwVal x) rg of
                                     (a, b) | even a -> b
                                     (_, b)          -> b - rg
            | True       = cwVal x `mod` (2 ^ sz)

-- | Size of a bit-vector, if finite. A Nothing value indicates
-- it's an unbounded Integer
newtype Size = Size { unSize :: Maybe Int }
               deriving (Eq, Ord)

-- | A symbolic node id.
newtype NodeId = NodeId Int deriving (Eq, Ord)

-- | A symbolic word, tracking it's signedness and size.
data SW        = SW (Bool, Size) NodeId deriving (Eq, Ord)

-- | Quantifiers: forall or exists. Note that we allow
-- arbitrary nestings.
data Quantifier = ALL | EX deriving Eq

-- | Are there any existential quantifiers?
needsExistentials :: [Quantifier] -> Bool
needsExistentials = (EX `elem`)

-- | Constant False as a SW. Note that this value always occupies slot -2.
falseSW :: SW
falseSW = SW (False, Size (Just 1)) $ NodeId (-2)

-- | Constant False as a SW. Note that this value always occupies slot -1.
trueSW :: SW
trueSW  = SW (False, Size (Just 1)) $ NodeId (-1)

-- | Constant False as a CW. We represent it using the integer value 0.
falseCW :: CW
falseCW = CW False (Size (Just 1)) 0

-- | Constant True as a CW. We represent it using the integer value 1.
trueCW :: CW
trueCW  = CW False (Size (Just 1)) 1

-- | A simple type for SBV computations, used mainly for uninterpreted constants.
-- We keep track of the signedness/size of the arguments. A non-function will
-- have just one entry in the list.
newtype SBVType = SBVType [(Bool, Size)]
             deriving (Eq, Ord)

-- | how many arguments does the type take?
typeArity :: SBVType -> Int
typeArity (SBVType xs) = length xs - 1

instance Show SBVType where
  show (SBVType []) = error "SBV: internal error, empty SBVType"
  show (SBVType xs) = intercalate " -> " $ map sh xs
    where sh (_,     Size Nothing)   = "SInteger"
          sh (False, Size (Just 1))  = "SBool"
          sh (s,     Size (Just sz)) = (if s then "SInt" else "SWord") ++ show sz

-- | Symbolic operations
data Op = Plus | Times | Minus
        | Quot | Rem -- quot and rem are unsigned only
        | Equal | NotEqual
        | LessThan | GreaterThan | LessEq | GreaterEq
        | Ite
        | And | Or  | XOr | Not
        | Shl Int | Shr Int | Rol Int | Ror Int
        | Extract Int Int -- Extract i j: extract bits i to j. Least significant bit is 0 (big-endian)
        | Join  -- Concat two words to form a bigger one, in the order given
        | LkUp (Int, (Bool, Size), (Bool, Size), Int) !SW !SW   -- (table-index, arg-type, res-type, length of the table) index out-of-bounds-value
        | ArrEq   Int Int
        | ArrRead Int
        | Uninterpreted String
        deriving (Eq, Ord)

-- | A symbolic expression
data SBVExpr = SBVApp !Op ![SW]
             deriving (Eq, Ord)

-- | A class for capturing values that have a sign and a size (finite or infinite)
-- minimal complete definition: sizeOf, hasSign
class HasSignAndSize a where
  sizeOf     :: a -> Size
  hasSign    :: a -> Bool
  intSizeOf  :: a -> Int
  isInfPrec  :: a -> Bool
  showType   :: a -> String
  showType a
    | isInfPrec a                         = "SInteger"
    | not (hasSign a) && intSizeOf a == 1 = "SBool"
    | True                                = (if hasSign a then "SInt" else "SWord") ++ show (intSizeOf a)
  isInfPrec = maybe True (const False) . unSize . sizeOf
  intSizeOf = fromMaybe (error "SBV.HasSignAndSize.bitSize((S)Integer)") . unSize . sizeOf

instance HasSignAndSize Bool    where {sizeOf _ = Size (Just 1) ; hasSign _ = False}
instance HasSignAndSize Int8    where {sizeOf _ = Size (Just 8) ; hasSign _ = True }
instance HasSignAndSize Word8   where {sizeOf _ = Size (Just 8) ; hasSign _ = False}
instance HasSignAndSize Int16   where {sizeOf _ = Size (Just 16); hasSign _ = True }
instance HasSignAndSize Word16  where {sizeOf _ = Size (Just 16); hasSign _ = False}
instance HasSignAndSize Int32   where {sizeOf _ = Size (Just 32); hasSign _ = True }
instance HasSignAndSize Word32  where {sizeOf _ = Size (Just 32); hasSign _ = False}
instance HasSignAndSize Int64   where {sizeOf _ = Size (Just 64); hasSign _ = True }
instance HasSignAndSize Word64  where {sizeOf _ = Size (Just 64); hasSign _ = False}
instance HasSignAndSize Integer where {sizeOf _ = Size Nothing;   hasSign _ = True}

-- | Lift a unary function thruough a CW
liftCW :: (Integer -> b) -> CW -> b
liftCW f x = f (cwVal x)

-- | Lift a binary function through a CW
liftCW2 :: (Integer -> Integer -> b) -> CW -> CW -> b
liftCW2 f x y | cwSameType x y = f (cwVal x) (cwVal y)
liftCW2 _ a b = error $ "SBV.liftCW2: impossible, incompatible args received: " ++ show (a, b)

-- | Map a unary function through a CW
mapCW :: (Integer -> Integer) -> CW -> CW
mapCW f x  = normCW $ x { cwVal = f (cwVal x) }

-- | Map a binary function through a CW
mapCW2 :: (Integer -> Integer -> Integer) -> CW -> CW -> CW
mapCW2 f x y
  | cwSameType x y = normCW $ CW (cwSigned x) (cwSize y) (f (cwVal x) (cwVal y))
mapCW2 _ a b = error $ "SBV.mapCW2: impossible, incompatible args received: " ++ show (a, b)

instance HasSignAndSize CW where
  intSizeOf = maybe (error "attempting to compute size of SInteger") id . unSize . cwSize
  sizeOf    = cwSize
  hasSign   = cwSigned
  isInfPrec = maybe True (const False) . unSize . cwSize

instance HasSignAndSize SW where
  sizeOf     (SW (_, s) _)   = s
  intSizeOf  (SW (_, mbs) _) = maybe (error "attempting to compute size of SInteger") id $ unSize mbs
  isInfPrec  (SW (_, mbs) _) = maybe True (const False) $ unSize mbs
  hasSign    (SW (b, _) _)   = b

instance Show CW where
  show w | cwIsBit w = show (cwToBool w)
  show w             = liftCW show w ++ " :: " ++ showType w

instance Show SW where
  show (SW _ (NodeId n))
    | n < 0 = "s_" ++ show (abs n)
    | True  = 's' : show n

instance Show Op where
  show (Shl i) = "<<"  ++ show i
  show (Shr i) = ">>"  ++ show i
  show (Rol i) = "<<<" ++ show i
  show (Ror i) = ">>>" ++ show i
  show (Extract i j) = "choose [" ++ show i ++ ":" ++ show j ++ "]"
  show (LkUp (ti, at, rt, l) i e)
        = "lookup(" ++ tinfo ++ ", " ++ show i ++ ", " ++ show e ++ ")"
        where tinfo = "table" ++ show ti ++ "(" ++ mkT at ++ " -> " ++ mkT rt ++ ", " ++ show l ++ ")"
              mkT (_, Size Nothing) = "SInteger"
              mkT (b, Size (Just s))
               | s == 1  = "SBool"
               | True    = if b then "SInt" else "SWord" ++ show s
  show (ArrEq i j)   = "array_" ++ show i ++ " == array_" ++ show j
  show (ArrRead i)   = "select array_" ++ show i
  show (Uninterpreted i) = "uninterpreted_" ++ i
  show op
    | Just s <- op `lookup` syms = s
    | True                       = error "impossible happened; can't find op!"
    where syms = [ (Plus, "+"), (Times, "*"), (Minus, "-")
                 , (Quot, "quot")
                 , (Rem,  "rem")
                 , (Equal, "=="), (NotEqual, "/=")
                 , (LessThan, "<"), (GreaterThan, ">"), (LessEq, "<"), (GreaterEq, ">")
                 , (Ite, "if_then_else")
                 , (And, "&"), (Or, "|"), (XOr, "^"), (Not, "~")
                 , (Join, "#")
                 ]

-- | To improve hash-consing, take advantage of commutative operators by
-- reordering their arguments.
reorder :: SBVExpr -> SBVExpr
reorder s = case s of
              SBVApp op [a, b] | isCommutative op && a > b -> SBVApp op [b, a]
              _ -> s
  where isCommutative :: Op -> Bool
        isCommutative o = o `elem` [Plus, Times, Equal, NotEqual, And, Or, XOr]

instance Show SBVExpr where
  show (SBVApp Ite [t, a, b]) = unwords ["if", show t, "then", show a, "else", show b]
  show (SBVApp (Shl i) [a])   = unwords [show a, "<<", show i]
  show (SBVApp (Shr i) [a])   = unwords [show a, ">>", show i]
  show (SBVApp (Rol i) [a])   = unwords [show a, "<<<", show i]
  show (SBVApp (Ror i) [a])   = unwords [show a, ">>>", show i]
  show (SBVApp op  [a, b])    = unwords [show a, show op, show b]
  show (SBVApp op  args)      = unwords (show op : map show args)

-- | A program is a sequence of assignments
type Pgm = S.Seq (SW, SBVExpr)

-- | 'NamedSymVar' pairs symbolic words and user given/automatically generated names
type NamedSymVar = (SW, String)

-- | 'UnintKind' pairs array names and uninterpreted constants with their "kinds"
-- used mainly for printing counterexamples
data UnintKind = UFun Int String | UArr Int String      -- in each case, arity and the aliasing name
 deriving Show

-- | Result of running a symbolic computation
data Result = Result Bool                                         -- contains unbounded integers
                     [(String, CW)]                               -- quick-check counter-example information (if any)
                     [(String, [String])]                         -- uninterpeted code segments
                     [(Quantifier, NamedSymVar)]                  -- inputs (possibly existential)
                     [(SW, CW)]                                   -- constants
                     [((Int, (Bool, Size), (Bool, Size)), [SW])]  -- tables (automatically constructed) (tableno, index-type, result-type) elts
                     [(Int, ArrayInfo)]                           -- arrays (user specified)
                     [(String, SBVType)]                          -- uninterpreted constants
                     [(String, [String])]                         -- axioms
                     Pgm                                          -- assignments
                     [SW]                                         -- additional constraints (boolean)
                     [SW]                                         -- outputs

-- | Extract the constraints from a result
getConstraints :: Result -> [SW]
getConstraints (Result _ _ _ _ _ _ _ _ _ _ cstrs _) = cstrs

-- | Extract the traced-values from a result (quick-check)
getTraceInfo :: Result -> [(String, CW)]
getTraceInfo (Result _ tvals _ _ _ _ _ _ _ _ _ _) = tvals

instance Show Result where
  show (Result _ _ _ _ cs _ _ [] [] _ [] [r])
    | Just c <- r `lookup` cs
    = show c
  show (Result _ _ cgs is cs ts as uis axs xs cstrs os)  = intercalate "\n" $
                   ["INPUTS"]
                ++ map shn is
                ++ ["CONSTANTS"]
                ++ map shc cs
                ++ ["TABLES"]
                ++ map sht ts
                ++ ["ARRAYS"]
                ++ map sha as
                ++ ["UNINTERPRETED CONSTANTS"]
                ++ map shui uis
                ++ ["USER GIVEN CODE SEGMENTS"]
                ++ concatMap shcg cgs
                ++ ["AXIOMS"]
                ++ map shax axs
                ++ ["DEFINE"]
                ++ map (\(s, e) -> "  " ++ shs s ++ " = " ++ show e) (F.toList xs)
                ++ ["CONSTRAINTS"]
                ++ map (("  " ++) . show) cstrs
                ++ ["OUTPUTS"]
                ++ map (("  " ++) . show) os
    where shs sw = show sw ++ " :: " ++ showType sw
          sht ((i, at, rt), es)  = "  Table " ++ show i ++ " : " ++ mkT at ++ "->" ++ mkT rt ++ " = " ++ show es
          shc (sw, cw) = "  " ++ show sw ++ " = " ++ show cw
          shcg (s, ss) = ("Variable: " ++ s) : map ("  " ++) ss
          shn (q, (sw, nm)) = "  " ++ ni ++ " :: " ++ showType sw ++ ex ++ alias
            where ni = show sw
                  ex | q == ALL = ""
                     | True     = ", existential"
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm
          sha (i, (nm, (ai, bi), ctx)) = "  " ++ ni ++ " :: " ++ mkT ai ++ " -> " ++ mkT bi ++ alias
                                       ++ "\n     Context: "     ++ show ctx
            where ni = "array_" ++ show i
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm
          shui (nm, t) = "  uninterpreted_" ++ nm ++ " :: " ++ show t
          shax (nm, ss) = "  -- user defined axiom: " ++ nm ++ "\n  " ++ intercalate "\n  " ss
          mkT (_, Size Nothing) = "SInteger"
          mkT (b, Size (Just s))
             | s == 1  = "SBool"
             | True    = if b then "SInt" else "SWord" ++ show s

-- | The context of a symbolic array as created
data ArrayContext = ArrayFree (Maybe SW)     -- ^ A new array, with potential initializer for each cell
                  | ArrayReset Int SW        -- ^ An array created from another array by fixing each element to another value
                  | ArrayMutate Int SW SW    -- ^ An array created by mutating another array at a given cell
                  | ArrayMerge  SW Int Int   -- ^ An array created by symbolically merging two other arrays

instance Show ArrayContext where
  show (ArrayFree Nothing)  = " initialized with random elements"
  show (ArrayFree (Just s)) = " initialized with " ++ show s ++ " :: " ++ showType s
  show (ArrayReset i s)     = " reset array_" ++ show i ++ " with " ++ show s ++ " :: " ++ showType s
  show (ArrayMutate i a b)  = " cloned from array_" ++ show i ++ " with " ++ show a ++ " :: " ++ showType a ++ " |-> " ++ show b ++ " :: " ++ showType b
  show (ArrayMerge s i j)   = " merged arrays " ++ show i ++ " and " ++ show j ++ " on condition " ++ show s

-- | Expression map, used for hash-consing
type ExprMap   = Map.Map SBVExpr SW

-- | Constants are stored in a map, for hash-consing
type CnstMap   = Map.Map CW SW

-- | Tables generated during a symbolic run
type TableMap  = Map.Map [SW] (Int, (Bool, Size), (Bool, Size))

-- | Representation for symbolic arrays
type ArrayInfo = (String, ((Bool, Size), (Bool, Size)), ArrayContext)

-- | Arrays generated during a symbolic run
type ArrayMap  = IMap.IntMap ArrayInfo

-- | Uninterpreted-constants generated during a symbolic run
type UIMap     = Map.Map String SBVType

-- | Code-segments for Uninterpreted-constants, as given by the user
type CgMap     = Map.Map String [String]

-- | Cached values, implementing sharing
type Cache a   = IMap.IntMap [(StableName (State -> IO a), a)]

-- | Convert an SBV-type to the kind-of uninterpreted value it represents
unintFnUIKind :: (String, SBVType) -> (String, UnintKind)
unintFnUIKind (s, t) = (s, UFun (typeArity t) s)

-- | Convert an array value type to the kind-of uninterpreted value it represents
arrayUIKind :: (Int, ArrayInfo) -> Maybe (String, UnintKind)
arrayUIKind (i, (nm, _, ctx)) 
  | external ctx = Just ("array_" ++ show i, UArr 1 nm) -- arrays are always 1-dimensional in the SMT-land. (Unless encoded explicitly)
  | True         = Nothing
  where external (ArrayFree{})   = True
        external (ArrayReset{})  = False
        external (ArrayMutate{}) = False
        external (ArrayMerge{})  = False

-- | Different means of running a symbolic piece of code
data SBVRunMode = Proof Bool      -- ^ Symbolic simulation mode, for proof purposes. Bool is True if it's a sat instance
                | CodeGen         -- ^ Code generation mode
                | Concrete StdGen -- ^ Concrete simulation mode. The StdGen is for the pConstrain acceptance in cross runs

-- | Is this a concrete run? (i.e., quick-check or test-generation like)
isConcreteMode :: SBVRunMode -> Bool
isConcreteMode (Concrete _) = True
isConcreteMode (Proof{})    = False
isConcreteMode CodeGen      = False

-- | The state of the symbolic interpreter
data State  = State { runMode       :: SBVRunMode
                    , rStdGen       :: IORef StdGen
                    , rCInfo        :: IORef [(String, CW)]
                    , rctr          :: IORef Int
                    , rInfPrec      :: IORef Bool
                    , rinps         :: IORef [(Quantifier, NamedSymVar)]
                    , rConstraints  :: IORef [SW]
                    , routs         :: IORef [SW]
                    , rtblMap       :: IORef TableMap
                    , spgm          :: IORef Pgm
                    , rconstMap     :: IORef CnstMap
                    , rexprMap      :: IORef ExprMap
                    , rArrayMap     :: IORef ArrayMap
                    , rUIMap        :: IORef UIMap
                    , rCgMap        :: IORef CgMap
                    , raxioms       :: IORef [(String, [String])]
                    , rSWCache      :: IORef (Cache SW)
                    , rAICache      :: IORef (Cache Int)
                    }

-- | Are we running in proof mode?
inProofMode :: State -> Bool
inProofMode s = case runMode s of
                  Proof{}    -> True
                  CodeGen    -> False
                  Concrete{} -> False

-- | The "Symbolic" value. Either a constant (@Left@) or a symbolic
-- value (@Right Cached@). Note that caching is essential for making
-- sure sharing is preserved. The parameter 'a' is phantom, but is
-- extremely important in keeping the user interface strongly typed.
data SBV a = SBV !(Bool, Size) !(Either CW (Cached SW))

-- | A symbolic boolean/bit
type SBool   = SBV Bool

-- | 8-bit unsigned symbolic value
type SWord8  = SBV Word8

-- | 16-bit unsigned symbolic value
type SWord16 = SBV Word16

-- | 32-bit unsigned symbolic value
type SWord32 = SBV Word32

-- | 64-bit unsigned symbolic value
type SWord64 = SBV Word64

-- | 8-bit signed symbolic value, 2's complement representation
type SInt8   = SBV Int8

-- | 16-bit signed symbolic value, 2's complement representation
type SInt16  = SBV Int16

-- | 32-bit signed symbolic value, 2's complement representation
type SInt32  = SBV Int32

-- | 64-bit signed symbolic value, 2's complement representation
type SInt64  = SBV Int64

-- | Infinite precision signed symbolic value
type SInteger = SBV Integer

-- Not particularly "desirable", but will do if needed
instance Show (SBV a) where
  show (SBV _                     (Left c))  = show c
  show (SBV (_  , Size Nothing)   (Right _)) = "<symbolic> :: SInteger"
  show (SBV (sgn, Size (Just sz)) (Right _)) = "<symbolic> :: " ++ t
                where t | not sgn && sz == 1 = "SBool"
                        | True               = (if sgn then "SInt" else "SWord") ++ show sz

-- Equality constraint on SBV values. Not desirable since we can't really compare two
-- symbolic values, but will do.
instance Eq (SBV a) where
  SBV _ (Left a) == SBV _ (Left b) = a == b
  a == b = error $ "Comparing symbolic bit-vectors; Use (.==) instead. Received: " ++ show (a, b)
  SBV _ (Left a) /= SBV _ (Left b) = a /= b
  a /= b = error $ "Comparing symbolic bit-vectors; Use (./=) instead. Received: " ++ show (a, b)

instance HasSignAndSize a => HasSignAndSize (SBV a) where
  sizeOf  _ = sizeOf  (undefined :: a)
  hasSign _ = hasSign (undefined :: a)

-- | Increment the variable counter
incCtr :: State -> IO Int
incCtr s = do ctr <- readIORef (rctr s)
              let i = ctr + 1
              i `seq` writeIORef (rctr s) i
              return ctr

-- | Generate a random value, for quick-check and test-gen purposes
throwDice :: State -> IO Double
throwDice st = do g <- readIORef (rStdGen st)
                  let (r, g') = randomR (0, 1) g
                  writeIORef (rStdGen st) g'
                  return r

-- | Create a new uninterpreted symbol, possibly with user given code
newUninterpreted :: State -> String -> SBVType -> Maybe [String] -> IO ()
newUninterpreted st nm t mbCode
  | null nm || not (isAlpha (head nm)) || not (all validChar (tail nm))
  = error $ "Bad uninterpreted constant name: " ++ show nm ++ ". Must be a valid identifier."
  | True = do
        uiMap <- readIORef (rUIMap st)
        case nm `Map.lookup` uiMap of
          Just t' -> if t /= t'
                     then error $  "Uninterpreted constant " ++ show nm ++ " used at incompatible types\n"
                                ++ "      Current type      : " ++ show t ++ "\n"
                                ++ "      Previously used at: " ++ show t'
                     else return ()
          Nothing -> do modifyIORef (rUIMap st) (Map.insert nm t)
                        when (isJust mbCode) $ modifyIORef (rCgMap st) (Map.insert nm (fromJust mbCode))
  where validChar x = isAlphaNum x || x `elem` "_"

-- | Create a new constant; hash-cons as necessary
newConst :: State -> CW -> IO SW
newConst st c = do
  constMap <- readIORef (rconstMap st)
  case c `Map.lookup` constMap of
    Just sw -> return sw
    Nothing -> do ctr <- incCtr st
                  let sw = SW (hasSign c, sizeOf c) (NodeId ctr)
                  when (isInfPrec sw) $ writeIORef (rInfPrec st) True
                  modifyIORef (rconstMap st) (Map.insert c sw)
                  return sw

-- | Create a new table; hash-cons as necessary
getTableIndex :: State -> (Bool, Size) -> (Bool, Size) -> [SW] -> IO Int
getTableIndex st at rt elts = do
  tblMap <- readIORef (rtblMap st)
  case elts `Map.lookup` tblMap of
    Just (i, _, _)  -> return i
    Nothing         -> do let i = Map.size tblMap
                          modifyIORef (rtblMap st) (Map.insert elts (i, at, rt))
                          return i

-- | Create a constant word
mkConstCW :: Integral a => (Bool, Size) -> a -> CW
mkConstCW (signed, size) a = normCW $ CW signed size (toInteger a)

-- | Create a new expression; hash-cons as necessary
newExpr :: State -> (Bool, Size) -> SBVExpr -> IO SW
newExpr st sgnsz app = do
   let e = reorder app
   exprMap <- readIORef (rexprMap st)
   case e `Map.lookup` exprMap of
     Just sw -> return sw
     Nothing -> do ctr <- incCtr st
                   let sw = SW sgnsz (NodeId ctr)
                   when (isInfPrec sw) $ writeIORef (rInfPrec st) True
                   modifyIORef (spgm st)     (flip (S.|>) (sw, e))
                   modifyIORef (rexprMap st) (Map.insert e sw)
                   return sw

-- | Convert a symbolic value to a symbolic-word
sbvToSW :: State -> SBV a -> IO SW
sbvToSW st (SBV _ (Left c))  = newConst st c
sbvToSW st (SBV _ (Right f)) = uncache f st

-------------------------------------------------------------------------
-- * Symbolic Computations
-------------------------------------------------------------------------
-- | A Symbolic computation. Represented by a reader monad carrying the
-- state of the computation, layered on top of IO for creating unique
-- references to hold onto intermediate results.
newtype Symbolic a = Symbolic (ReaderT State IO a)
                   deriving (Functor, Monad, MonadIO, MonadReader State)

-- | Create a symbolic value, based on the quantifier we have. If an explicit quantifier is given, we just use that.
-- If not, then we pick existential for SAT calls and universal for everything else.
mkSymSBV :: forall a. (Random a, SymWord a) => Maybe Quantifier -> (Bool, Size) -> Maybe String -> Symbolic (SBV a)
mkSymSBV mbQ sgnsz mbNm = do
        st <- ask
        let q = case (mbQ, runMode st) of
                  (Just x,  _)           -> x   -- user given, just take it
                  (Nothing, Concrete{})  -> ALL -- concrete simulation, pick universal
                  (Nothing, Proof True)  -> EX  -- sat mode, pick existential
                  (Nothing, Proof False) -> ALL -- proof mode, pick universal
                  (Nothing, CodeGen)     -> ALL -- code generation, pick universal
        case runMode st of
          Concrete _ | q == EX -> case mbNm of
                                    Nothing -> error $ "Cannot quick-check in the presence of existential variables, type: " ++ showType (undefined :: SBV a)
                                    Just nm -> error $ "Cannot quick-check in the presence of existential variable " ++ nm ++ " :: " ++ showType (undefined :: SBV a)
          Concrete _           -> do v@(SBV _ (Left cw)) <- liftIO randomIO
                                     liftIO $ modifyIORef (rCInfo st) ((maybe "_" id mbNm, cw):)
                                     return v
          _          -> do ctr <- liftIO $ incCtr st
                           let nm = maybe ('s':show ctr) id mbNm
                               sw = SW sgnsz (NodeId ctr)
                           when (isInfPrec sw) $ liftIO $ writeIORef (rInfPrec st) True
                           liftIO $ modifyIORef (rinps st) ((q, (sw, nm)):)
                           return $ SBV sgnsz $ Right $ cache (const (return sw))

-- | Convert a symbolic value to an SW, inside the Symbolic monad
sbvToSymSW :: SBV a -> Symbolic SW
sbvToSymSW sbv = do
        st <- ask
        liftIO $ sbvToSW st sbv

-- | A class representing what can be returned from a symbolic computation.
class Outputtable a where
  -- | Mark an interim result as an output. Useful when constructing Symbolic programs
  -- that return multiple values, or when the result is programmatically computed.
  output :: a -> Symbolic a

instance Outputtable (SBV a) where
  output i@(SBV _ (Left c)) = do
          st <- ask
          sw <- liftIO $ newConst st c
          liftIO $ modifyIORef (routs st) (sw:)
          return i
  output i@(SBV _ (Right f)) = do
          st <- ask
          sw <- liftIO $ uncache f st
          liftIO $ modifyIORef (routs st) (sw:)
          return i

instance Outputtable a => Outputtable [a] where
  output = mapM output

instance Outputtable () where
  output = return

instance (Outputtable a, Outputtable b) => Outputtable (a, b) where
  output = mlift2 (,) output output

instance (Outputtable a, Outputtable b, Outputtable c) => Outputtable (a, b, c) where
  output = mlift3 (,,) output output output

instance (Outputtable a, Outputtable b, Outputtable c, Outputtable d) => Outputtable (a, b, c, d) where
  output = mlift4 (,,,) output output output output

instance (Outputtable a, Outputtable b, Outputtable c, Outputtable d, Outputtable e) => Outputtable (a, b, c, d, e) where
  output = mlift5 (,,,,) output output output output output

instance (Outputtable a, Outputtable b, Outputtable c, Outputtable d, Outputtable e, Outputtable f) => Outputtable (a, b, c, d, e, f) where
  output = mlift6 (,,,,,) output output output output output output

instance (Outputtable a, Outputtable b, Outputtable c, Outputtable d, Outputtable e, Outputtable f, Outputtable g) => Outputtable (a, b, c, d, e, f, g) where
  output = mlift7 (,,,,,,) output output output output output output output

instance (Outputtable a, Outputtable b, Outputtable c, Outputtable d, Outputtable e, Outputtable f, Outputtable g, Outputtable h) => Outputtable (a, b, c, d, e, f, g, h) where
  output = mlift8 (,,,,,,,) output output output output output output output output

-- | Add a user specified axiom to the generated SMT-Lib file. Note that the input is a
-- mere string; we perform no checking on the input that it's well-formed or is sensical.
-- A separate formalization of SMT-Lib would be very useful here.
addAxiom :: String -> [String] -> Symbolic ()
addAxiom nm ax = do
        st <- ask
        liftIO $ modifyIORef (raxioms st) ((nm, ax) :)

-- | Run a symbolic computation in Proof mode and return a 'Result'. The boolean
-- argument indicates if this is a sat instance or not.
runSymbolic :: Bool -> Symbolic a -> IO Result
runSymbolic b c = snd `fmap` runSymbolic' (Proof b) c

-- | Run a symbolic computation, and return a extra value paired up with the 'Result'
runSymbolic' :: SBVRunMode -> Symbolic a -> IO (a, Result)
runSymbolic' currentRunMode (Symbolic c) = do
   ctr     <- newIORef (-2) -- start from -2; False and True will always occupy the first two elements
   cInfo   <- newIORef []
   pgm     <- newIORef S.empty
   emap    <- newIORef Map.empty
   cmap    <- newIORef Map.empty
   inps    <- newIORef []
   outs    <- newIORef []
   tables  <- newIORef Map.empty
   arrays  <- newIORef IMap.empty
   uis     <- newIORef Map.empty
   cgs     <- newIORef Map.empty
   axioms  <- newIORef []
   swCache <- newIORef IMap.empty
   aiCache <- newIORef IMap.empty
   infPrec <- newIORef False
   cstrs   <- newIORef []
   rGen    <- case currentRunMode of
                Concrete g -> newIORef g
                _          -> newStdGen >>= newIORef
   let st = State { runMode      = currentRunMode
                  , rStdGen      = rGen
                  , rCInfo       = cInfo
                  , rctr         = ctr
                  , rInfPrec     = infPrec
                  , rinps        = inps
                  , routs        = outs
                  , rtblMap      = tables
                  , spgm         = pgm
                  , rconstMap    = cmap
                  , rArrayMap    = arrays
                  , rexprMap     = emap
                  , rUIMap       = uis
                  , rCgMap       = cgs
                  , raxioms      = axioms
                  , rSWCache     = swCache
                  , rAICache     = aiCache
                  , rConstraints = cstrs
                  }
   _ <- newConst st (mkConstCW (False, Size (Just 1)) (0::Integer)) -- s(-2) == falseSW
   _ <- newConst st (mkConstCW (False, Size (Just 1)) (1::Integer)) -- s(-1) == trueSW
   r <- runReaderT c st
   rpgm  <- readIORef pgm
   inpsO <- reverse `fmap` readIORef inps
   outsO <- reverse `fmap` readIORef outs
   let swap (a, b) = (b, a)
       cmp  (a, _) (b, _) = a `compare` b
   cnsts <- (sortBy cmp . map swap . Map.toList) `fmap` readIORef (rconstMap st)
   tbls  <- (sortBy (\((x, _, _), _) ((y, _, _), _) -> x `compare` y) . map swap . Map.toList) `fmap` readIORef tables
   arrs  <- IMap.toAscList `fmap` readIORef arrays
   unint <- Map.toList `fmap` readIORef uis
   axs   <- reverse `fmap` readIORef axioms
   hasInfPrec <- readIORef infPrec
   cgMap <- Map.toList `fmap` readIORef cgs
   traceVals <- reverse `fmap` readIORef cInfo
   extraCstrs   <- reverse `fmap` readIORef cstrs
   return $ (r, Result hasInfPrec traceVals cgMap inpsO cnsts tbls arrs unint axs rpgm extraCstrs outsO)

-------------------------------------------------------------------------------
-- * Symbolic Words
-------------------------------------------------------------------------------
-- | A 'SymWord' is a potential symbolic bitvector that can be created instances of
-- to be fed to a symbolic program. Note that these methods are typically not needed
-- in casual uses with 'prove', 'sat', 'allSat' etc, as default instances automatically
-- provide the necessary bits.
--
-- Minimal complete definiton: forall, forall_, exists, exists_, literal, fromCW
class (HasSignAndSize a, Ord a) => SymWord a where
  -- | Create a user named input (universal)
  forall :: String -> Symbolic (SBV a)
  -- | Create an automatically named input
  forall_ :: Symbolic (SBV a)
  -- | Get a bunch of new words
  mkForallVars :: Int -> Symbolic [SBV a]
  -- | Create an existential variable
  exists  :: String -> Symbolic (SBV a)
  -- | Create an automatically named existential variable
  exists_ :: Symbolic (SBV a)
  -- | Create a bunch of existentials
  mkExistVars :: Int -> Symbolic [SBV a]
  -- | Create a free variable, universal in a proof, existential in sat
  free :: String -> Symbolic (SBV a)
  -- | Create an unnamed free variable, universal in proof, existential in sat
  free_ :: Symbolic (SBV a)
  -- | Create a bunch of free vars
  mkFreeVars :: Int -> Symbolic [SBV a]
  -- | Turn a literal constant to symbolic
  literal :: a -> SBV a
  -- | Extract a literal, if the value is concrete
  unliteral :: SBV a -> Maybe a
  -- | Extract a literal, from a CW representation
  fromCW :: CW -> a
  -- | Is the symbolic word concrete?
  isConcrete :: SBV a -> Bool
  -- | Is the symbolic word really symbolic?
  isSymbolic :: SBV a -> Bool
  -- | Does it concretely satisfy the given predicate?
  isConcretely :: SBV a -> (a -> Bool) -> Bool
  -- | max/minbounds, if available. Note that we don't want
  -- to impose "Bounded" on our class as Integer is not Bounded but it is a SymWord
  mbMaxBound, mbMinBound :: Maybe a

  -- minimal complete definiton: forall, forall_, exists, exists_, free, free_, literal, fromCW
  mkForallVars n = mapM (const forall_) [1 .. n]
  mkExistVars n  = mapM (const exists_) [1 .. n]
  mkFreeVars n   = mapM (const free_)   [1 .. n]
  unliteral (SBV _ (Left c))  = Just $ fromCW c
  unliteral _                 = Nothing
  isConcrete (SBV _ (Left _)) = True
  isConcrete _                = False
  isSymbolic = not . isConcrete
  isConcretely s p
    | Just i <- unliteral s = p i
    | True                  = False

instance (Random a, SymWord a) => Random (SBV a) where
  randomR (l, h) g = case (unliteral l, unliteral h) of
                       (Just lb, Just hb) -> let (v, g') = randomR (lb, hb) g in (literal (v :: a), g')
                       _                  -> error $ "SBV.Random: Cannot generate random values with symbolic bounds"
  random         g = let (v, g') = random g in (literal (v :: a) , g')
---------------------------------------------------------------------------------
-- * Symbolic Arrays
---------------------------------------------------------------------------------

-- | Flat arrays of symbolic values
-- An @array a b@ is an array indexed by the type @'SBV' a@, with elements of type @'SBV' b@
-- If an initial value is not provided in 'newArray_' and 'newArray' methods, then the elements
-- are left unspecified, i.e., the solver is free to choose any value. This is the right thing
-- to do if arrays are used as inputs to functions to be verified, typically. 
--
-- While it's certainly possible for user to create instances of 'SymArray', the
-- 'SArray' and 'SFunArray' instances already provided should cover most use cases
-- in practice. (There are some differences between these models, however, see the corresponding
-- declaration.)
--
--
-- Minimal complete definition: All methods are required, no defaults.
class SymArray array where
  -- | Create a new array, with an optional initial value
  newArray_      :: (HasSignAndSize a, HasSignAndSize b) => Maybe (SBV b) -> Symbolic (array a b)
  -- | Create a named new array, with an optional initial value
  newArray       :: (HasSignAndSize a, HasSignAndSize b) => String -> Maybe (SBV b) -> Symbolic (array a b)
  -- | Read the array element at @a@
  readArray      :: array a b -> SBV a -> SBV b
  -- | Reset all the elements of the array to the value @b@
  resetArray     :: SymWord b => array a b -> SBV b -> array a b
  -- | Update the element at @a@ to be @b@
  writeArray     :: SymWord b => array a b -> SBV a -> SBV b -> array a b
  -- | Merge two given arrays on the symbolic condition
  -- Intuitively: @mergeArrays cond a b = if cond then a else b@.
  -- Merging pushes the if-then-else choice down on to elements
  mergeArrays    :: SymWord b => SBV Bool -> array a b -> array a b -> array a b

-- | Arrays implemented in terms of SMT-arrays: <http://goedel.cs.uiowa.edu/smtlib/theories/ArraysEx.smt2>
--
--   * Maps directly to SMT-lib arrays
--
--   * Reading from an unintialized value is OK and yields an uninterpreted result
--
--   * Can check for equality of these arrays
--
--   * Cannot quick-check theorems using @SArray@ values
--
--   * Typically slower as it heavily relies on SMT-solving for the array theory
--
data SArray a b = SArray ((Bool, Size), (Bool, Size)) (Cached ArrayIndex)

-- | An array index is simple an int value
type ArrayIndex = Int

instance (HasSignAndSize a, HasSignAndSize b) => Show (SArray a b) where
  show (SArray{}) = "SArray<" ++ showType (undefined :: a) ++ ":" ++ showType (undefined :: b) ++ ">"

instance SymArray SArray where
  newArray_  = declNewSArray (\t -> "array_" ++ show t)
  newArray n = declNewSArray (const n)
  readArray (SArray (_, bsgnsz) f) a = SBV bsgnsz $ Right $ cache r
     where r st = do arr <- uncacheAI f st
                     i   <- sbvToSW st a
                     newExpr st bsgnsz (SBVApp (ArrRead arr) [i])
  resetArray (SArray ainfo f) b = SArray ainfo $ cache g
     where g st = do amap <- readIORef (rArrayMap st)
                     val <- sbvToSW st b
                     i <- uncacheAI f st
                     let j = IMap.size amap
                     j `seq` modifyIORef (rArrayMap st) (IMap.insert j ("array_" ++ show j, ainfo, ArrayReset i val))
                     return j
  writeArray (SArray ainfo f) a b = SArray ainfo $ cache g
     where g st = do arr  <- uncacheAI f st
                     addr <- sbvToSW st a
                     val  <- sbvToSW st b
                     amap <- readIORef (rArrayMap st)
                     let j = IMap.size amap
                     j `seq` modifyIORef (rArrayMap st) (IMap.insert j ("array_" ++ show j, ainfo, ArrayMutate arr addr val))
                     return j
  mergeArrays t (SArray ainfo a) (SArray _ b) = SArray ainfo $ cache h
    where h st = do ai <- uncacheAI a st
                    bi <- uncacheAI b st
                    ts <- sbvToSW st t
                    amap <- readIORef (rArrayMap st)
                    let k = IMap.size amap
                    k `seq` modifyIORef (rArrayMap st) (IMap.insert k ("array_" ++ show k, ainfo, ArrayMerge ts ai bi))
                    return k

-- | Declare a new symbolic array, with a potential initial value
declNewSArray :: forall a b. (HasSignAndSize a, HasSignAndSize b) => (Int -> String) -> Maybe (SBV b) -> Symbolic (SArray a b)
declNewSArray mkNm mbInit = do
   let asgnsz = (hasSign (undefined :: a), sizeOf (undefined :: a))
       bsgnsz = (hasSign (undefined :: b), sizeOf (undefined :: b))
   st <- ask
   amap <- liftIO $ readIORef $ rArrayMap st
   let i = IMap.size amap
       nm = mkNm i
   actx <- liftIO $ case mbInit of
                     Nothing   -> return $ ArrayFree Nothing
                     Just ival -> sbvToSW st ival >>= \sw -> return $ ArrayFree (Just sw)
   liftIO $ modifyIORef (rArrayMap st) (IMap.insert i (nm, (asgnsz, bsgnsz), actx))
   return $ SArray (asgnsz, bsgnsz) $ cache $ const $ return i

-- | Arrays implemented internally as functions
--
--    * Internally handled by the library and not mapped to SMT-Lib
--
--    * Reading an uninitialized value is considered an error (will throw exception)
--
--    * Cannot check for equality (internally represented as functions)
--
--    * Can quick-check
--
--    * Typically faster as it gets compiled away during translation
--
data SFunArray a b = SFunArray (SBV a -> SBV b)

instance (HasSignAndSize a, HasSignAndSize b) => Show (SFunArray a b) where
  show (SFunArray _) = "SFunArray<" ++ showType (undefined :: a) ++ ":" ++ showType (undefined :: b) ++ ">"

-- | Lift a function to an array. Useful for creating arrays in a pure context. (Otherwise use `newArray`.)
mkSFunArray :: (SBV a -> SBV b) -> SFunArray a b
mkSFunArray = SFunArray

-- | Handling constraints
imposeConstraint :: SBool -> Symbolic ()
imposeConstraint c = do st <- ask
                        case runMode st of
                          CodeGen -> error "SBV: constraints are not allowed in code-generation"
                          _       -> do liftIO $ do v <- sbvToSW st c
                                                    modifyIORef (rConstraints st) (v:)

-- | Add a constraint with a given probability
addConstraint :: Maybe Double -> SBool -> SBool -> Symbolic ()
addConstraint Nothing  c _  = imposeConstraint c
addConstraint (Just t) c c'
  | t < 0 || t > 1
  = error $ "SBV: pConstrain: Invalid probability threshold: " ++ show t ++ ", must be in [0, 1]."
  | True
  = do st <- ask
       when (not (isConcreteMode (runMode st))) $ error "SBV: pConstrain only allowed in 'genTest' or 'quickCheck' contexts."
       case () of
         () | t > 0 && t < 1 -> liftIO (throwDice st) >>= \d -> imposeConstraint (if d <= t then c else c')
            | t > 0          -> imposeConstraint c
            | True           -> imposeConstraint c'

---------------------------------------------------------------------------------
-- * Cached values
---------------------------------------------------------------------------------

-- | We implement a peculiar caching mechanism, applicable to the use case in
-- implementation of SBV's.  Whenever we do a state based computation, we do
-- not want to keep on evaluating it in the then-current state. That will
-- produce essentially a semantically equivalent value. Thus, we want to run
-- it only once, and reuse that result, capturing the sharing at the Haskell
-- level. This is similar to the "type-safe observable sharing" work, but also
-- takes into the account of how symbolic simulation executes.
--
-- See Andy Gill's type-safe obervable sharing trick for the inspiration behind
-- this technique: <http://ittc.ku.edu/~andygill/paper.php?label=DSLExtract09>
--
-- Note that this is *not* a general memo utility!
newtype Cached a = Cached (State -> IO a)

-- | Cache a state-based computation
cache :: (State -> IO a) -> Cached a
cache = Cached

-- | Uncache a previously cached computation
uncache :: Cached SW -> State -> IO SW
uncache = uncacheGen rSWCache

-- | Uncache, retrieving array indexes
uncacheAI :: Cached ArrayIndex -> State -> IO ArrayIndex
uncacheAI = uncacheGen rAICache

-- | Generic uncaching. Note that this is entirely safe, since we do it in the IO monad.
uncacheGen :: (State -> IORef (Cache a)) -> Cached a -> State -> IO a
uncacheGen getCache (Cached f) st = do
        let rCache = getCache st
        stored <- readIORef rCache
        sn <- f `seq` makeStableName f
        let h = hashStableName sn
        case maybe Nothing (sn `lookup`) (h `IMap.lookup` stored) of
          Just r  -> return r
          Nothing -> do r <- f st
                        r `seq` modifyIORef rCache (IMap.insertWith (++) h [(sn, r)])
                        return r

-- | Representation of SMTLib Program versions, currently we only know of versions 1 and 2.
-- (NB. Eventually, we should just drop SMTLib1.)
data SMTLibVersion = SMTLib1
                   | SMTLib2
                   deriving Eq

-- | Representation of an SMT-Lib program. In between pre and post goes the refuted models
data SMTLibPgm = SMTLibPgm SMTLibVersion  ( [(String, SW)]          -- alias table
                                          , [String]                -- pre: declarations.
                                          , [String])               -- post: formula
instance NFData SMTLibVersion
instance NFData SMTLibPgm

instance Show SMTLibPgm where
  show (SMTLibPgm _ (_, pre, post)) = intercalate "\n" $ pre ++ post

-- Other Technicalities..
instance NFData CW where
  rnf (CW x y z) = x `seq` y `seq` z `seq` ()

instance NFData Result where
  rnf (Result isInf qcInfo cgs inps consts tbls arrs uis axs pgm cstr outs)
        = rnf isInf `seq` rnf qcInfo `seq` rnf cgs `seq` rnf inps `seq` rnf consts `seq` rnf tbls `seq` rnf arrs `seq` rnf uis `seq` rnf axs `seq` rnf pgm `seq` rnf cstr `seq` rnf outs

instance NFData Size
instance NFData ArrayContext
instance NFData Pgm
instance NFData SW
instance NFData Quantifier
instance NFData SBVType
instance NFData UnintKind
instance NFData a => NFData (Cached a) where
  rnf (Cached f) = f `seq` ()
instance NFData a => NFData (SBV a) where
  rnf (SBV x y) = rnf x `seq` rnf y `seq` ()
