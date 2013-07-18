{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

module Bindings.GDAL.Internal (
    Datatype (..)
  , Access (..)
  , ColorInterpretation (..)
  , PaletteInterpretation (..)
  , Error (..)
  , Geotransform (..)
  , MaybeIOVector
  , ProgressFun

  , DriverOptions

  , MajorObject
  , Dataset
  , Band
  , Driver
  , ColorTable
  , RasterAttributeTable

  , registerAllDrivers
  , driverByName
  , create
  , create'
  , createMem
  , flushCache
  , open
  , openShared
  , createCopy'
  , createCopy

  , datatypeSize
  , datatypeByName
  , datatypeUnion
  , datatypeIsComplex

  , datasetProjection
  , setDatasetProjection
  , datasetGeotransform
  , setDatasetGeotransform

  , withBand
  , bandDatatype
  , bandBlockSize
  , bandblockLen
  , bandSize
  , bandNodataValue
  , setBandNodataValue
  , readBand
  , readBandBlock
  , writeBand
  , writeBandBlock
  , fillBand

) where

import Control.Applicative (liftA2, (<$>), (<*>))
import Control.Concurrent (newMVar, takeMVar, putMVar, MVar)
import Control.Exception (finally, bracket)
import Control.Monad (liftM, foldM)

import Data.Int (Int16, Int32)
import Data.Complex (Complex(..), realPart, imagPart)
import Data.Typeable (Typeable, cast, typeOf)
import Data.Word (Word8, Word16, Word32)
import Data.Vector.Storable (Vector, unsafeFromForeignPtr0, unsafeToForeignPtr0)
import Foreign.C.String (withCString, CString, peekCString)
import Foreign.C.Types (CDouble(..), CInt(..), CChar(..))
import Foreign.Ptr (Ptr, FunPtr, castPtr, nullPtr, freeHaskellFunPtr)
import Foreign.Storable (Storable(..))
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr, newForeignPtr
                          ,mallocForeignPtrArray)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Marshal.Utils (toBool, fromBool)

import System.IO.Unsafe (unsafePerformIO)

#include "gdal.h"
#include "cpl_string.h"
#include "cpl_error.h"

{# enum CPLErr as Error {upcaseFirstLetter} deriving (Eq,Show) #}

{# enum GDALDataType as Datatype {upcaseFirstLetter} deriving (Eq) #}
instance Show Datatype where
   show = getDatatypeName

{# fun pure unsafe GDALGetDataTypeSize as datatypeSize
    { fromEnumC `Datatype' } -> `Int' #}

{# fun pure unsafe GDALDataTypeIsComplex as datatypeIsComplex
    { fromEnumC `Datatype' } -> `Bool' #}

{# fun pure unsafe GDALGetDataTypeName as getDatatypeName
    { fromEnumC `Datatype' } -> `String' #}

{# fun pure unsafe GDALGetDataTypeByName as datatypeByName
    { `String' } -> `Datatype' toEnumC #}

{# fun pure unsafe GDALDataTypeUnion as datatypeUnion
    { fromEnumC `Datatype', fromEnumC `Datatype' } -> `Datatype' toEnumC #}


{# enum GDALAccess as Access {upcaseFirstLetter} deriving (Eq, Show) #}

{# enum GDALRWFlag as RwFlag {upcaseFirstLetter} deriving (Eq, Show) #}

{# enum GDALColorInterp as ColorInterpretation {upcaseFirstLetter}
   deriving (Eq) #}

instance Show ColorInterpretation where
    show = getColorInterpretationName

{# fun pure unsafe GDALGetColorInterpretationName as getColorInterpretationName
    { fromEnumC `ColorInterpretation' } -> `String' #}

{# fun pure unsafe GDALGetColorInterpretationByName as getColorInterpretationByName
    { `String' } -> `ColorInterpretation' toEnumC #}


{# enum GDALPaletteInterp as PaletteInterpretation {upcaseFirstLetter}
   deriving (Eq) #}

instance Show PaletteInterpretation where
    show = getPaletteInterpretationName

{# fun pure unsafe GDALGetPaletteInterpretationName as getPaletteInterpretationName
    { fromEnumC `PaletteInterpretation' } -> `String' #}


{#pointer GDALMajorObjectH as MajorObject newtype#}
{#pointer GDALDatasetH as Dataset foreign newtype nocode#}

newtype Dataset = Dataset (ForeignPtr Dataset, Mutex)

withDataset, withDataset' :: Dataset -> (Ptr Dataset -> IO b) -> IO b
withDataset ds@(Dataset (_, m)) fun = withMutex m $ withDataset' ds fun

withDataset' (Dataset (fptr,_)) = withForeignPtr fptr

{#pointer GDALRasterBandH as Band newtype#}
{#pointer GDALDriverH as Driver newtype#}
{#pointer GDALColorTableH as ColorTable newtype#}
{#pointer GDALRasterAttributeTableH as RasterAttributeTable newtype#}

{# fun GDALAllRegister as registerAllDrivers {} -> `()'  #}

{# fun unsafe GDALGetDriverByName as c_driverByName
    { `String' } -> `Driver' id #}

driverByName :: String -> IO (Maybe Driver)
driverByName s = do
    driver@(Driver ptr) <- c_driverByName s
    return $ if ptr==nullPtr then Nothing else Just driver


type DriverOptions = [(String,String)]

create :: String -> String -> Int -> Int -> Int -> Datatype -> DriverOptions
       -> IO (Maybe Dataset)
create drv path nx ny bands dtype options = do
    driver <- driverByName drv
    case driver of
      Nothing -> return Nothing
      Just d  -> create' d path nx ny bands dtype options

create' :: Driver -> String -> Int -> Int -> Int -> Datatype -> DriverOptions
       -> IO (Maybe Dataset)
create' drv path nx ny bands dtype options = withCString path $ \path' -> do
    opts <- toOptionList options
    ptr <- {#call GDALCreate as ^#}
             drv
             path'
             (fromIntegral nx)
             (fromIntegral ny)
             (fromIntegral bands)
             (fromEnumC dtype)
             opts
    newDatasetHandle ptr

{# fun GDALOpen as open
    { `String', fromEnumC `Access'} -> `Maybe Dataset' newDatasetHandle* #}

{# fun GDALOpen as openShared
    { `String', fromEnumC `Access'} -> `Maybe Dataset' newDatasetHandle* #}

createCopy' :: Driver -> String -> Dataset -> Bool -> DriverOptions
            -> ProgressFun -> IO (Maybe Dataset)
createCopy' driver path dataset strict options progressFun
  = withCString path $ \p ->
    withDataset dataset $ \ds ->
    withProgressFun progressFun $ \pFunc -> do
        let s = fromBool strict
        o <- toOptionList options
        {#call GDALCreateCopy as ^#} driver p ds s o pFunc (castPtr nullPtr) >>=
            newDatasetHandle

withProgressFun f = bracket (wrapProgressFun f) freeHaskellFunPtr

createCopy :: String -> String -> Dataset -> Bool -> DriverOptions
           -> IO (Maybe Dataset)
createCopy driver path dataset strict options = do
    d <- driverByName driver
    case d of
      Nothing -> return Nothing
      Just d' -> createCopy' d' path dataset strict options (\_ _ _ -> return 1)

type ProgressFun = CDouble -> Ptr CChar -> Ptr () -> IO CInt

foreign import ccall "wrapper"
  wrapProgressFun :: ProgressFun -> IO (FunPtr ProgressFun)


newDatasetHandle :: Ptr Dataset -> IO (Maybe Dataset)
newDatasetHandle p =
    if p==nullPtr then return Nothing
    else do fp <- newForeignPtr closeDataset p
            mutex <- newMutex
            return $ Just $ Dataset (fp, mutex)

foreign import ccall "gdal.h &GDALClose"
  closeDataset :: FunPtr (Ptr (Dataset) -> IO ())

createMem:: Int -> Int -> Int -> Datatype -> DriverOptions -> IO (Maybe Dataset)
createMem = create "MEM" ""

{# fun GDALFlushCache as flushCache
    {  withDataset*  `Dataset'} -> `()' #}

{# fun unsafe GDALGetProjectionRef as datasetProjection
    {  withDataset*  `Dataset'} -> `String' #}

{# fun unsafe GDALSetProjection as setDatasetProjection
    {  withDataset*  `Dataset', `String'} -> `Error' toEnumC #}

data Geotransform = Geotransform !Double !Double !Double !Double !Double !Double
    deriving (Eq, Show)

datasetGeotransform :: Dataset -> IO (Maybe Geotransform)
datasetGeotransform ds = withDataset' ds $ \dPtr -> do
    allocaArray 6 $ \a -> do
      err <- {#call unsafe GDALGetGeoTransform as ^#} dPtr a
      case toEnumC err of
           CE_None -> liftM Just $ Geotransform
                       <$> liftM realToFrac (peekElemOff a 0)
                       <*> liftM realToFrac (peekElemOff a 1)
                       <*> liftM realToFrac (peekElemOff a 2)
                       <*> liftM realToFrac (peekElemOff a 3)
                       <*> liftM realToFrac (peekElemOff a 4)
                       <*> liftM realToFrac (peekElemOff a 5)
           _       -> return Nothing

setDatasetGeotransform :: Dataset -> Geotransform -> IO (Error)
setDatasetGeotransform ds gt = withDataset ds $ \dPtr -> do
    allocaArray 6 $ \a -> do
        let (Geotransform g0 g1 g2 g3 g4 g5) = gt
        pokeElemOff a 0 (realToFrac g0)
        pokeElemOff a 1 (realToFrac g1)
        pokeElemOff a 2 (realToFrac g2)
        pokeElemOff a 3 (realToFrac g3)
        pokeElemOff a 4 (realToFrac g4)
        pokeElemOff a 5 (realToFrac g5)
        liftM toEnumC $ {#call unsafe GDALSetGeoTransform as ^#} dPtr a

withBand :: Dataset -> Int -> (Maybe Band -> IO a) -> IO a
withBand ds band f = withDataset ds $ \dPtr -> do
    rBand@(Band p) <- {# call unsafe GDALGetRasterBand as ^ #}
                              dPtr (fromIntegral band)
    f (if p == nullPtr then Nothing else Just rBand)

{# fun pure unsafe GDALGetRasterDataType as bandDatatype
   { id `Band'} -> `Datatype' toEnumC #}

bandBlockSize :: Band -> (Int,Int)
bandBlockSize band = unsafePerformIO $ alloca $ \xPtr -> alloca $ \yPtr ->
   {#call unsafe GDALGetBlockSize as ^#} band xPtr yPtr >>
   liftA2 (,) (liftM fromIntegral $ peek xPtr) (liftM fromIntegral $ peek yPtr)

bandblockLen :: Band -> Int
bandblockLen = uncurry (*) . bandBlockSize

bandSize :: Band -> (Int, Int)
bandSize band
  = ( fromIntegral . {# call pure unsafe GDALGetRasterBandXSize as ^#} $ band
    , fromIntegral . {# call pure unsafe GDALGetRasterBandYSize as ^#} $ band
    )

bandNodataValue :: Band -> IO (Maybe Double)
bandNodataValue b = alloca $ \p -> do
   value <- liftM realToFrac $ {#call unsafe GDALGetRasterNoDataValue as ^#} b p
   hasNodata <- liftM toBool $ peek p
   return (if hasNodata then Just value else Nothing)
   
{# fun GDALSetRasterNoDataValue as setBandNodataValue
   { id `Band', `Double'} -> `Error' toEnumC #}

{# fun GDALFillRaster as fillBand
    { id `Band', `Double', `Double'} -> `Error' toEnumC #}

class HasDatatype a where
    datatype :: a -> Datatype

instance HasDatatype (Ptr Word8)  where datatype _ = GDT_Byte
instance HasDatatype (Ptr Word16) where datatype _ = GDT_UInt16
instance HasDatatype (Ptr Word32) where datatype _ = GDT_UInt32
instance HasDatatype (Ptr Int16)  where datatype _ = GDT_Int16
instance HasDatatype (Ptr Int32)  where datatype _ = GDT_Int32
instance HasDatatype (Ptr Float)  where datatype _ = GDT_Float32
instance HasDatatype (Ptr Double) where datatype _ = GDT_Float64
-- GDT_CInt16 or GDT_CInt32 can be written as Complex (Float|Double) but
-- will be truncated by GDAL. Both can be read as Complex (Float|Double).
-- This is a limitation imposed by Complex a which constrains a to be a
-- RealFloat.
instance HasDatatype (Ptr (Complex Float)) where datatype _ = GDT_CFloat32
instance HasDatatype (Ptr (Complex Double)) where datatype _ = GDT_CFloat64


instance (RealFloat a, Storable a) => Storable (Complex a) where
  sizeOf _ = sizeOf (undefined :: a) * 2
  alignment _ = alignment (undefined :: a)
 
  {-# SPECIALIZE INLINE peek :: Ptr (Complex Float) -> IO (Complex Float) #-}
  {-# SPECIALIZE INLINE peek :: Ptr (Complex Double) -> IO (Complex Double) #-}
  peek p = (:+) <$> peekElemOff (castPtr p) 0 <*> peekElemOff (castPtr p) 1

  {-# SPECIALIZE INLINE
      poke :: Ptr (Complex Float) -> Complex Float -> IO () #-}
  {-# SPECIALIZE INLINE
      poke :: Ptr (Complex Double) -> Complex Double -> IO () #-}
  poke p v = pokeElemOff (castPtr p) 0 (realPart v) >>
             pokeElemOff (castPtr p) 1 (imagPart v)



readBand :: (Storable a, HasDatatype (Ptr a))
  => Band
  -> Int -> Int
  -> Int -> Int
  -> Int -> Int
  -> Int -> Int
  -> IO (Maybe (Vector a))
readBand band xoff yoff sx sy bx by pxs lns = do
    fp <- mallocForeignPtrArray (bx * by)
    err <- withForeignPtr fp $ \ptr -> do
        _ <- {#call GDALRasterAdviseRead as ^#}
          band
          (fromIntegral xoff)
          (fromIntegral yoff)
          (fromIntegral sx)
          (fromIntegral sy)
          (fromIntegral bx)
          (fromIntegral by)
          (fromEnumC (datatype ptr))
          (castPtr nullPtr)
        {#call GDALRasterIO as ^#}
          band
          (fromEnumC GF_Read) 
          (fromIntegral xoff)
          (fromIntegral yoff)
          (fromIntegral sx)
          (fromIntegral sy)
          (castPtr ptr)
          (fromIntegral bx)
          (fromIntegral by)
          (fromEnumC (datatype ptr))
          (fromIntegral pxs)
          (fromIntegral lns)
    case toEnumC err of
         CE_None -> return $ Just $ unsafeFromForeignPtr0 fp (bx * by)
         _       -> return Nothing
        
writeBand :: (Storable a, HasDatatype (Ptr a))
  => Band
  -> Int -> Int
  -> Int -> Int
  -> Int -> Int
  -> Int -> Int
  -> Vector a
  -> IO (Error)
writeBand band xoff yoff sx sy bx by pxs lns vec = do
    let nElems    = bx * by
        (fp, len) = unsafeToForeignPtr0 vec
    if nElems /= len
      then return CE_Failure
      else withForeignPtr fp $ \ptr -> liftM toEnumC $
          {#call GDALRasterIO as ^#}
            band
            (fromEnumC GF_Write) 
            (fromIntegral xoff)
            (fromIntegral yoff)
            (fromIntegral sx)
            (fromIntegral sy)
            (castPtr ptr)
            (fromIntegral bx)
            (fromIntegral by)
            (fromEnumC (datatype ptr))
            (fromIntegral pxs)
            (fromIntegral lns)

data Block where
    Block :: (Typeable a, Storable a) => Vector a -> Block

readBandBlock :: (Storable a, Typeable a)
  => Band -> Int -> Int -> MaybeIOVector a
readBandBlock b x y = do
  block <- readBandBlock' b x y
  liftM (maybe Nothing (\(Block a) -> cast a)) $ readBandBlock' b x y


readBandBlock' :: Band -> Int -> Int -> IO (Maybe Block)
readBandBlock' b x y = 
  case bandDatatype b of
    GDT_Byte ->
      maybeReturn Block (readIt b x y :: MaybeIOVector Word8)
    GDT_Int16 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector Int16)
    GDT_Int32 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector Int32)
    GDT_Float32 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector Float)
    GDT_Float64 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector Double)
    GDT_CInt16 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector (Complex Float))
    GDT_CInt32 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector (Complex Double))
    GDT_CFloat32 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector (Complex Float))
    GDT_CFloat64 ->
      maybeReturn Block (readIt b x y :: MaybeIOVector (Complex Double))
    _ -> return Nothing
  where
    maybeReturn f act = act >>= maybe (return Nothing) (return . Just . f)
    readIt b x y = do
      let l  = bandblockLen b
          rb = {#call GDALReadBlock as ^#} b (fromIntegral x) (fromIntegral y)
      f <- mallocForeignPtrArray l
      e <- withForeignPtr f (rb . castPtr)
      if toEnumC e == CE_None
         then return $ Just $ unsafeFromForeignPtr0 f l
         else return Nothing

type MaybeIOVector a = IO (Maybe (Vector a))

writeBandBlock :: (Storable a, Typeable a)
  => Band
  -> Int -> Int
  -> Vector a
  -> IO (Error)
writeBandBlock b x y vec = do
    let nElems    = bandblockLen b
        (fp, len) = unsafeToForeignPtr0 vec
    if nElems /= len || typeOf vec /= typeOfBand b
      then return CE_Failure
      else withForeignPtr fp $ \ptr -> liftM toEnumC $
          {#call GDALWriteBlock as ^#}
            b
            (fromIntegral x)
            (fromIntegral y)
            (castPtr ptr)

typeOfBand = typeOfdatatype . bandDatatype

typeOfdatatype dt =
  case dt of
    GDT_Byte     -> typeOf (undefined :: Vector Word8)
    GDT_Int16    -> typeOf (undefined :: Vector Int16)
    GDT_Int32    -> typeOf (undefined :: Vector Int32)
    GDT_Float32  -> typeOf (undefined :: Vector Float)
    GDT_Float64  -> typeOf (undefined :: Vector Double)
    GDT_CInt16   -> typeOf (undefined :: Vector (Complex Float))
    GDT_CInt32   -> typeOf (undefined :: Vector (Complex Double))
    GDT_CFloat32 -> typeOf (undefined :: Vector (Complex Float))
    GDT_CFloat64 -> typeOf (undefined :: Vector (Complex Double))
    _            -> typeOf (undefined :: Bool) -- will never match a vector

fromEnumC :: Enum a => a -> CInt
fromEnumC = fromIntegral . fromEnum

toEnumC :: Enum a => CInt -> a
toEnumC = toEnum . fromIntegral


toOptionList :: [(String,String)] -> IO (Ptr CString)
toOptionList opts =  foldM folder nullPtr opts
  where folder acc (k,v) = withCString k $ \k' -> withCString v $ \v' ->
                           {#call unsafe CSLSetNameValue as ^#} acc k' v'

type Mutex = MVar ()

newMutex :: IO Mutex
newMutex = newMVar ()


acquireMutex :: Mutex -> IO ()
acquireMutex = takeMVar

releaseMutex :: Mutex -> IO ()
releaseMutex m = putMVar m ()

withMutex m action = finally (acquireMutex m >> action) (releaseMutex m)
