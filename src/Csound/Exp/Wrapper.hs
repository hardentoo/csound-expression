{-# Language 
        TypeSynonymInstances,
        FlexibleInstances #-}
module Csound.Exp.Wrapper where

import Control.Applicative
import Control.Monad(ap)
import Control.Monad.Trans.State

import Data.String
import Data.Fix
import Control.Monad.Trans.State

import Csound.Exp
import Csound.Exp.NumExp
import Csound.Exp.Inline
import qualified Csound.Exp.NumExp as NumExp

type Channel = Int

-- | Outupt of the instrument.
type Out = SE [Sig]


-- | Audio or control rate signals. 
newtype Sig = Sig { unSig :: E }

-- | Integers.
newtype I = I { unI :: E }

-- | Doubles.
newtype D = D { unD :: E }

-- | Strings.
newtype S = S { unS :: E }

-- | Boolean signals. Use functions from the module "Data.Boolean" to make boolean signals
-- out of simple signals.
newtype BoolSig = BoolSig { unBoolSig :: E }

-- | Spectrum of the signal (see "FFT and Spectral Processing" in the "Csound.Opcode.Advanced"). 
newtype Spec = Spec { unSpec :: E }

------------------------------------------------
-- side effects

-- | Csound's synonym for 'IO'-monad. 'SE' means Side Effect. 
-- You will bump into 'SE' trying to read and write to delay lines,
-- making random signals or trying to save your audio to file. 
-- Instrument is expected to return a value of @SE [Sig]@. 
-- So it's okay to do some side effects when playing a note.
newtype SE a = SE { unSE :: State E a }

instance Functor SE where
    fmap f = SE . fmap f . unSE

instance Applicative SE where
    pure = return
    (<*>) = ap

instance Monad SE where
    return = SE . return
    ma >>= mf = SE $ unSE ma >>= unSE . mf

runSE :: SE a -> (a, E)
runSE a = runState (unSE a) (unD (p 3 :: D))

execSE :: SE a -> E
execSE = snd . runSE

------------------------------------------------
-- basic constructors
  
noRate :: Val a => Exp E -> a
noRate = ratedExp Nothing
  
withRate :: Val a => Rate -> Exp E -> a
withRate r = ratedExp (Just r)

ratedExp :: Val a => Maybe Rate -> Exp E -> a
ratedExp r = wrap . RatedExp r Nothing

prim :: Val a => Prim -> a
prim = wrap . noRate . ExpPrim 
 

pref :: Name -> Signature -> Info
pref name signature = Info name signature Prefix Nothing

inf :: Name -> Signature -> Info
inf name signature = Info name signature Infix Nothing
  
tfm :: Val a => Info -> [RatedExp E] -> a
tfm info args = wrap $ noRate $ Tfm info $ map Fix args

opc :: Val a => Name -> Signature -> [RatedExp E] -> a
opc name signature = tfm (pref name signature)

opr :: Val a => Name -> Signature -> [RatedExp E] -> a
opr name signature = tfm (inf name signature)

gvar, var :: Val a => Rate -> Name -> a

var  = mkVar LocalVar 
gvar = mkVar GlobalVar

mkVar :: Val a => VarType -> Rate -> String -> a
mkVar ty rate name = wrap $ noRate $ ReadVar (Var ty rate name)

p :: Init a => Int -> a
p = prim . P

-- | Converts Haskell's integers to Csound's integers
int :: Int -> I
int = prim . PrimInt

-- | Converts Haskell's doubles to Csound's doubles
double :: Double -> D
double = prim . PrimDouble

-- | Converts Haskell's strings to Csound's strings
str :: String -> S
str = prim . PrimString

writeVar :: (Val a) => Var -> a -> SE ()
writeVar v x = se_ $ noRate $ WriteVar v $ Fix $ unwrap x 

readVar :: (Val a) => Var -> a
readVar v = noRate $ ReadVar v

gOutVar :: Int -> Int -> Var
gOutVar instrId portId = Var GlobalVar Ar (gOutName instrId portId)
    where gOutName instrId portId = "Out" ++ show instrId ++ "_" ++ show portId

-------------------------------
-- side effects

se :: (Val a) => E -> SE a
se a = SE $ state $ \s -> 
    let x = (unwrap a) { ratedExpDepends = Just s }
    in  (wrap x, Fix $ x)

se_ :: E -> SE ()
se_ = fmap (const ()) . SE . withState setProcedure . unSE . (se :: E -> SE E)

setProcedure :: E -> E
setProcedure x = x {- Fix $ case unFix x of 
    a -> a{ ratedExpExp = phi $ ratedExpExp a } 
    where phi (Tfm i xs) = Tfm i{ infoOpcType = Procedure } xs
          phi x = x  
  -}          

------------------------------------------------
-- basic destructors

getPrimUnsafe :: Val a => a -> Prim
getPrimUnsafe a = case ratedExpExp $ unwrap a of
    ExpPrim p -> p



--------------------------------------------
-- signals from primitive types

-- | Values that can be converted to signals. 
class ToSig a where
    sig :: a -> Sig
    
instance ToSig I where
    sig = wrap . unwrap

instance ToSig D where
    sig = wrap . unwrap

instance ToSig Sig where
    sig = id
    
instance ToSig Int where
    sig = sig . int
    
instance ToSig Double where
    sig = sig . double

--------------------------------------------
-- rate conversion 

setRate :: (Val a, Val b) => Rate -> a -> b
setRate r a = wrap $ (\x -> x { ratedExpRate = Just r }) $ unwrap a

-- | Forces signal to audio rate. 
ar :: ToSig a => a -> Sig
ar = setRate Ar . sig

-- | Forces signal to control rate.
kr :: ToSig a => a -> Sig
kr = setRate Kr . sig

-- | Converts signal to double.
ir :: Sig -> D
ir = setRate Ir

------------------------------------------------------
-- inits

-- types that can be used in score

class Val a => Init a where

instance Init I where
instance Init D where
instance Init S where
instance Init Tab where

------------------------------------------------------
-- values

class Val a where
    wrap    :: RatedExp E -> a 
    unwrap  :: a -> RatedExp E

instance Val (RatedExp E) where
    wrap = id
    unwrap = id
     
instance Val E where
    wrap = Fix
    unwrap = unFix
     
instance Val Sig where
    wrap = Sig . Fix
    unwrap = unFix . unSig

instance Val I where
    wrap = I . Fix
    unwrap = unFix . unI

instance Val D where
    wrap = D . Fix
    unwrap = unFix . unD

instance Val S where
    wrap = S . Fix
    unwrap = unFix . unS

instance Val Tab where
    wrap = un
    unwrap = prim . PrimTab

instance Val BoolSig where
    wrap = BoolSig . Fix
    unwrap = unFix . unBoolSig 

instance Val Spec where
    wrap = Spec . Fix
    unwrap = unFix . unSpec

------------------------------------------------
-- arguments

data ArgMethods a = ArgMethods 
    { arg :: Int -> a
    , toNote :: a -> [Prim]
    , arity :: a -> Int
    }

toArg :: Arg a => a
toArg = arg argMethods 4

makeArgMethods :: (Arg a) => (a -> b) -> (b -> a) -> ArgMethods b
makeArgMethods to from = ArgMethods {
    arg = to . arg argMethods,
    toNote = toNote argMethods . from,
    arity = arity argMethods . from }

class Arg a where
    argMethods :: ArgMethods a

instance Arg I where
    argMethods = ArgMethods {
        arg = p,
        toNote = pure . getPrimUnsafe,
        arity = const 1 }
         
instance Arg D where
    argMethods = ArgMethods {
        arg = p,
        toNote = pure . getPrimUnsafe,
        arity = const 1 }

instance Arg S where
    argMethods = ArgMethods {
        arg = p,
        toNote = pure . getPrimUnsafe,
        arity = const 1 }

instance Arg Tab where
    argMethods = ArgMethods {
        arg = p,
        toNote = pure . getPrimUnsafe,
        arity = const 1 }

instance (Arg a, Arg b) => Arg (a, b) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b)
                  where a = arg argMethods n
                        b = arg argMethods (n + arity argMethods a)
              toNote' (a, b) = toNote argMethods a ++ toNote argMethods b
              arity' (a, b) = arity argMethods a + arity argMethods b    

instance (Arg a, Arg b, Arg c) => Arg (a, b, c) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
              toNote' (a, b, c) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c
              arity' (a, b, c) = arity argMethods a + arity argMethods b + arity argMethods c

instance (Arg a, Arg b, Arg c, Arg d) => Arg (a, b, c, d) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c, d)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
                        nd = nc + arity argMethods c
                        d = arg argMethods nd
              toNote' (a, b, c, d) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c ++ toNote argMethods d
              arity' (a, b, c, d) = arity argMethods a + arity argMethods b + arity argMethods c + arity argMethods d

instance (Arg a, Arg b, Arg c, Arg d, Arg e) => Arg (a, b, c, d, e) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c, d, e)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
                        nd = nc + arity argMethods c
                        d = arg argMethods nd
                        ne = nd + arity argMethods d
                        e = arg argMethods ne
              toNote' (a, b, c, d, e) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c ++ toNote argMethods d ++ toNote argMethods e
              arity' (a, b, c, d, e) = arity argMethods a + arity argMethods b + arity argMethods c + arity argMethods d + arity argMethods e

instance (Arg a, Arg b, Arg c, Arg d, Arg e, Arg f) => Arg (a, b, c, d, e, f) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c, d, e, f)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
                        nd = nc + arity argMethods c
                        d = arg argMethods nd
                        ne = nd + arity argMethods d
                        e = arg argMethods ne
                        nf = ne + arity argMethods e
                        f = arg argMethods nf
              toNote' (a, b, c, d, e, f) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c ++ toNote argMethods d ++ toNote argMethods e ++ toNote argMethods f
              arity' (a, b, c, d, e, f) = arity argMethods a + arity argMethods b + arity argMethods c + arity argMethods d + arity argMethods e + arity argMethods f


instance (Arg a, Arg b, Arg c, Arg d, Arg e, Arg f, Arg g) => Arg (a, b, c, d, e, f, g) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c, d, e, f, g)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
                        nd = nc + arity argMethods c
                        d = arg argMethods nd
                        ne = nd + arity argMethods d
                        e = arg argMethods ne
                        nf = ne + arity argMethods e
                        f = arg argMethods nf
                        ng = nf + arity argMethods f
                        g = arg argMethods ng
              toNote' (a, b, c, d, e, f, g) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c ++ toNote argMethods d ++ toNote argMethods e ++ toNote argMethods f ++ toNote argMethods g
              arity' (a, b, c, d, e, f, g) = arity argMethods a + arity argMethods b + arity argMethods c + arity argMethods d + arity argMethods e + arity argMethods f + arity argMethods g

instance (Arg a, Arg b, Arg c, Arg d, Arg e, Arg f, Arg g, Arg h) => Arg (a, b, c, d, e, f, g, h) where
    argMethods = ArgMethods arg' toNote' arity' 
        where arg' n = (a, b, c, d, e, f, g, h)
                  where a = arg argMethods n
                        nb = n + arity argMethods a
                        b = arg argMethods nb
                        nc = nb + arity argMethods b
                        c = arg argMethods nc
                        nd = nc + arity argMethods c
                        d = arg argMethods nd
                        ne = nd + arity argMethods d
                        e = arg argMethods ne
                        nf = ne + arity argMethods e
                        f = arg argMethods nf
                        ng = nf + arity argMethods f
                        g = arg argMethods ng
                        nh = ng + arity argMethods g
                        h = arg argMethods nh
              toNote' (a, b, c, d, e, f, g, h) = toNote argMethods a ++ toNote argMethods b ++ toNote argMethods c ++ toNote argMethods d ++ toNote argMethods e ++ toNote argMethods f ++ toNote argMethods g ++ toNote argMethods h
              arity' (a, b, c, d, e, f, g, h) = arity argMethods a + arity argMethods b + arity argMethods c + arity argMethods d + arity argMethods e + arity argMethods f + arity argMethods g + arity argMethods h


------------------------------------------------
-- tuples

class CsdTuple a where
    fromCsdTuple :: a -> [E]
    toCsdTuple :: [E] -> a
    arityCsdTuple :: a -> Int

instance CsdTuple Sig where
    fromCsdTuple = return . Fix . unwrap
    toCsdTuple = wrap . unFix . head
    arityCsdTuple = const 1

instance CsdTuple I where
    fromCsdTuple = return . Fix . unwrap
    toCsdTuple = wrap . unFix . head
    arityCsdTuple = const 1

instance CsdTuple D where
    fromCsdTuple = return . Fix . unwrap
    toCsdTuple = wrap . unFix . head
    arityCsdTuple = const 1

instance CsdTuple S where
    fromCsdTuple = return . Fix . unwrap
    toCsdTuple = wrap . unFix . head
    arityCsdTuple = const 1

instance CsdTuple Spec where
    fromCsdTuple = return . Fix . unwrap
    toCsdTuple = wrap . unFix . head
    arityCsdTuple = const 1

instance (CsdTuple a, CsdTuple b) => CsdTuple (a, b) where
    fromCsdTuple (a, b) = fromCsdTuple a ++ fromCsdTuple b
    arityCsdTuple (a, b) = arityCsdTuple a + arityCsdTuple b
    toCsdTuple xs = (a, b)
        where a = toCsdTuple $ take (arityCsdTuple a) xs
              xsb = drop (arityCsdTuple a) xs  
              b = toCsdTuple (take (arityCsdTuple b) xsb)

instance (CsdTuple a, CsdTuple b, CsdTuple c) => CsdTuple (a, b, c) where
    fromCsdTuple (a, b, c) = fromCsdTuple a ++ fromCsdTuple b ++ fromCsdTuple c
    arityCsdTuple (a, b, c) = arityCsdTuple a + arityCsdTuple b + arityCsdTuple c
    toCsdTuple xs = (a, b, c)
        where a = toCsdTuple $ take (arityCsdTuple a) xs
              xsb = drop (arityCsdTuple a) xs  
              b = toCsdTuple (take (arityCsdTuple b) xsb)
              xsc = drop (arityCsdTuple b) xsb
              c = toCsdTuple (take (arityCsdTuple c) xsc)

instance (CsdTuple a, CsdTuple b, CsdTuple c, CsdTuple d) => CsdTuple (a, b, c, d) where
    fromCsdTuple (a, b, c, d) = fromCsdTuple a ++ fromCsdTuple b ++ fromCsdTuple c ++ fromCsdTuple d
    arityCsdTuple (a, b, c, d) = arityCsdTuple a + arityCsdTuple b + arityCsdTuple c + arityCsdTuple d
    toCsdTuple xs = (a, b, c, d)
        where a = toCsdTuple $ take (arityCsdTuple a) xs
              xsb = drop (arityCsdTuple a) xs  
              b = toCsdTuple (take (arityCsdTuple b) xsb)
              xsc = drop (arityCsdTuple b) xsb
              c = toCsdTuple (take (arityCsdTuple c) xsc)
              xsd = drop (arityCsdTuple c) xsc
              d = toCsdTuple (take (arityCsdTuple d) xsd)            

------------------------------------------------
-- multiple outs

fromE :: Val a => E -> a
fromE = wrap . unFix 

multiOuts :: CsdTuple a => E -> a
multiOuts exp = res
    where res = toCsdTuple $ multiOutsSection (arityCsdTuple res) exp

multiOutsSection :: Int -> E -> [E]
multiOutsSection n e = zipWith (\n r -> select n r e') [0 ..] rates
    where rates = take n $ getRates $ ratedExpExp $ unFix e          
          e' = Fix $ onExp (setMultiRate rates) $ unFix e
          
          setMultiRate rates (Tfm info xs) = Tfm (info{ infoSignature = MultiRate rates ins }) xs 
            where MultiRate _ ins = infoSignature info
            
          select n r e = withRate r $ Select r n e

getRates :: Exp a -> [Rate]
getRates (Tfm info _) = case infoSignature info of
    MultiRate outs _ -> outs
    
isMultiOutSignature :: Signature -> Bool
isMultiOutSignature x = case x of
    MultiRate _ _ -> True
    _ -> False

