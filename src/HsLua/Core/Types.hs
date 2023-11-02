{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-|
Module      : HsLua.Core.Types
Copyright   : © 2007–2012 Gracjan Polak;
              © 2012–2016 Ömer Sinan Ağacan;
              © 2017-2022 Albert Krewinkel
License     : MIT
Maintainer  : Albert Krewinkel <tarleb+hslua@zeitkraut.de>
Stability   : beta
Portability : non-portable (depends on GHC)

The core Lua types, including mappings of Lua types to Haskell.

This module has mostly been moved to @'Lua.Types'@ and
currently re-exports that module. This module might be removed in
the future.
-}
module HsLua.Core.Types
  ( LuaE (..)
  , LuaEnvironment (..)
  , State (..)
  , Reader
  , liftLua
  , liftLua1
  , state
  , runWith
  , unsafeRunWith
  , GCControl (..)
  , toGCcode
  , toGCdata
  , Type (..)
  , fromType
  , toType
  , liftIO
  , CFunction
  , PreCFunction
  , HaskellFunction
  , LuaBool (..)
  , fromLuaBool
  , toLuaBool
  , Integer (..)
  , Number (..)
  , StackIndex (..)
  , registryindex
  , NumArgs (..)
  , NumResults (..)
  , multret
  , RelationalOperator (..)
  , fromRelationalOperator
  , Status (..)
  , toStatus
    -- * References
  , Reference (..)
  , fromReference
  , toReference
  , noref
  , refnil
    -- * Stack index helpers
  , nthTop
  , nthBottom
  , nth
  , top
    -- * Table field names
  , Name (..)
  ) where

import Prelude hiding (Integer, EQ, LT)

import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Reader (ReaderT (..), MonadReader, MonadIO, asks, liftIO)
import Data.ByteString (ByteString)
import Data.String (IsString (..))
import Foreign.C (CInt)
import Lua (nth, nthBottom, nthTop, top)
import Lua.Constants
import Lua.Types
import Lua.Auxiliary
  ( Reference (..)
  , fromReference
  , toReference
  )
import qualified HsLua.Core.Utf8 as Utf8
#if !MIN_VERSION_base(4,12,0)
import Data.Semigroup (Semigroup)
#endif

-- | Environment in which Lua computations are evaluated.
newtype LuaEnvironment = LuaEnvironment
  { luaEnvState :: State -- ^ Lua interpreter state
  }

-- | A Lua computation. This is the base type used to run Lua programs
-- of any kind. The Lua state is handled automatically, but can be
-- retrieved via @'state'@.
newtype LuaE e a = Lua { unLua :: ReaderT LuaEnvironment IO a }
  deriving
    ( Applicative
    , Functor
    , Monad
    , MonadCatch
    , MonadIO
    , MonadMask
    , MonadReader LuaEnvironment
    , MonadThrow
    )

-- | Turn a function of typ @Lua.State -> IO a@ into a monadic Lua
-- operation.
liftLua :: (State -> IO a) -> LuaE e a
liftLua f = state >>= liftIO . f
{-# INLINABLE liftLua #-}

-- | Turn a function of typ @Lua.State -> a -> IO b@ into a monadic Lua
-- operation.
liftLua1 :: (State -> a -> IO b) -> a -> LuaE e b
liftLua1 f x = liftLua $ \l -> f l x
{-# INLINABLE liftLua1 #-}

-- | Get the Lua state of this Lua computation.
state :: LuaE e State
state = asks luaEnvState
{-# INLINABLE state #-}

-- | Run Lua computation with the given Lua state. Exception handling is
-- left to the caller; resulting exceptions are left unhandled.
runWith :: State -> LuaE e a -> IO a
runWith l s = runReaderT (unLua s) (LuaEnvironment l)
{-# INLINABLE runWith #-}

-- | Run the given operation, but crash if any Haskell exceptions occur.
unsafeRunWith :: State -> LuaE e a -> IO a
unsafeRunWith = runWith

-- | Haskell function that can be called from Lua.
-- The HsLua equivallent of a 'PreCFunction'.
type HaskellFunction e = LuaE e NumResults

--
-- Type of Lua values
--

-- | Enumeration used as type tag.
-- See <https://www.lua.org/manual/5.3/manual.html#lua_type lua_type>.
data Type
  = TypeNone           -- ^ non-valid stack index
  | TypeNil            -- ^ type of Lua's @nil@ value
  | TypeBoolean        -- ^ type of Lua booleans
  | TypeLightUserdata  -- ^ type of light userdata
  | TypeNumber         -- ^ type of Lua numbers. See @'Lua.Number'@
  | TypeString         -- ^ type of Lua string values
  | TypeTable          -- ^ type of Lua tables
  | TypeFunction       -- ^ type of functions, either normal or @'CFunction'@
  | TypeUserdata       -- ^ type of full user data
  | TypeThread         -- ^ type of Lua threads
  deriving (Bounded, Eq, Ord, Show)

instance Enum Type where
  fromEnum = fromIntegral . fromTypeCode . fromType
  toEnum = toType . TypeCode . fromIntegral

-- | Convert a Lua 'Type' to a type code which can be passed to the C
-- API.
fromType :: Type -> TypeCode
fromType = \case
  TypeNone          -> LUA_TNONE
  TypeNil           -> LUA_TNIL
  TypeBoolean       -> LUA_TBOOLEAN
  TypeLightUserdata -> LUA_TLIGHTUSERDATA
  TypeNumber        -> LUA_TNUMBER
  TypeString        -> LUA_TSTRING
  TypeTable         -> LUA_TTABLE
  TypeFunction      -> LUA_TFUNCTION
  TypeUserdata      -> LUA_TUSERDATA
  TypeThread        -> LUA_TTHREAD
{-# INLINABLE fromType #-}

-- | Convert numerical code to Lua 'Type'.
toType :: TypeCode -> Type
toType = \case
  LUA_TNONE          -> TypeNone
  LUA_TNIL           -> TypeNil
  LUA_TBOOLEAN       -> TypeBoolean
  LUA_TLIGHTUSERDATA -> TypeLightUserdata
  LUA_TNUMBER        -> TypeNumber
  LUA_TSTRING        -> TypeString
  LUA_TTABLE         -> TypeTable
  LUA_TFUNCTION      -> TypeFunction
  LUA_TUSERDATA      -> TypeUserdata
  LUA_TTHREAD        -> TypeThread
  TypeCode c         -> error ("No Type corresponding to " ++ show c)
{-# INLINABLE toType #-}


--
-- Thread status
--

-- | Lua status values.
data Status
  = OK        -- ^ success
  | Yield     -- ^ yielding / suspended coroutine
  | ErrRun    -- ^ a runtime rror
  | ErrSyntax -- ^ syntax error during precompilation
  | ErrMem    -- ^ memory allocation (out-of-memory) error.
  | ErrErr    -- ^ error while running the message handler.
  | ErrGcmm   -- ^ error while running a @__gc@ metamethod.
  | ErrFile   -- ^ opening or reading a file failed.
  deriving (Eq, Show)

-- | Convert C integer constant to @'Status'@.
toStatus :: StatusCode -> Status
toStatus = \case
  LUA_OK        -> OK
  LUA_YIELD     -> Yield
  LUA_ERRRUN    -> ErrRun
  LUA_ERRSYNTAX -> ErrSyntax
  LUA_ERRMEM    -> ErrMem
  LUA_ERRGCMM   -> ErrGcmm
  LUA_ERRERR    -> ErrErr
  LUA_ERRFILE   -> ErrFile
  StatusCode n  -> error $ "Cannot convert (" ++ show n ++ ") to Status"
{-# INLINABLE toStatus #-}

--
-- Relational Operator
--

-- | Lua comparison operations.
data RelationalOperator
  = EQ -- ^ Correponds to Lua's equality (==) operator.
  | LT -- ^ Correponds to Lua's strictly-lesser-than (<) operator
  | LE -- ^ Correponds to Lua's lesser-or-equal (<=) operator
  deriving (Eq, Ord, Show)

-- | Convert relation operator to its C representation.
fromRelationalOperator :: RelationalOperator -> OPCode
fromRelationalOperator = \case
  EQ -> LUA_OPEQ
  LT -> LUA_OPLT
  LE -> LUA_OPLE
{-# INLINABLE fromRelationalOperator #-}

--
-- Boolean
--

-- | Convert a @'LuaBool'@ to a Haskell @'Bool'@.
fromLuaBool :: LuaBool -> Bool
fromLuaBool FALSE = False
fromLuaBool _     = True
{-# INLINABLE fromLuaBool #-}

-- | Convert a Haskell @'Bool'@ to a @'LuaBool'@.
toLuaBool :: Bool -> LuaBool
toLuaBool True  = TRUE
toLuaBool False = FALSE
{-# INLINABLE toLuaBool #-}

--
-- Garbage collection
--

-- | Commands to control the garbage collector.
data GCControl
  = GCStop            -- ^ stops the garbage collector.
  | GCRestart         -- ^ restarts the garbage collector
  | GCCollect         -- ^ performs a full garbage-collection cycle.
  | GCCount           -- ^ returns the current amount of memory (in
                      -- Kbytes) in use by Lua.
  | GCCountb          -- ^ returns the remainder of dividing the current
                      -- amount of bytes of memory in use by Lua by 1024.
  | GCStep            -- ^ performs an incremental step of garbage
                      -- collection.
  | GCSetPause CInt   -- ^ sets data as the new value for the pause of
                      -- the collector (see
                      -- <https://www.lua.org/manual/5.3/manual.html#2.5
                      -- §2.5> of the Lua reference manual) and returns
                      -- the previous value of the pause.
  | GCSetStepMul CInt -- ^ sets data as the new value for the step
                      -- multiplier of the collector (see
                      -- <https://www.lua.org/manual/5.3/manual.html#2.5
                      -- §2.5> of the Lua reference manual) and returns
                      -- the previous value of the step multiplier.
  | GCIsRunning       -- ^ returns a boolean that tells whether the
                      -- collector is running (i.e., not stopped).
  deriving (Eq, Ord, Show)

-- | Converts a GCControl command to its corresponding code.
toGCcode :: GCControl -> GCCode
toGCcode = \case
  GCStop          -> LUA_GCSTOP
  GCRestart       -> LUA_GCRESTART
  GCCollect       -> LUA_GCCOLLECT
  GCCount         -> LUA_GCCOUNT
  GCCountb        -> LUA_GCCOUNTB
  GCStep          -> LUA_GCSTEP
  GCSetPause {}   -> LUA_GCSETPAUSE
  GCSetStepMul {} -> LUA_GCSETSTEPMUL
  GCIsRunning     -> LUA_GCISRUNNING
{-# INLINABLE toGCcode #-}

-- | Returns the data value associated with a GCControl command.
toGCdata :: GCControl -> CInt
toGCdata = \case
  GCSetPause p   -> p
  GCSetStepMul m -> m
  _              -> 0
{-# INLINABLE toGCdata #-}

--
-- Special values
--

-- | Option for multiple returns in @'HsLua.Core.pcall'@.
multret :: NumResults
multret = LUA_MULTRET

-- | Pseudo stack index of the Lua registry.
registryindex :: StackIndex
registryindex = LUA_REGISTRYINDEX

-- | Value signaling that no reference was created.
refnil :: Int
refnil = fromIntegral LUA_REFNIL

-- | Value signaling that no reference was found.
noref :: Int
noref = fromIntegral LUA_NOREF

--
-- Field names
--

-- | Name of a function, table field, or chunk; the name must be valid
-- UTF-8 and may not contain any nul characters.
--
-- Implementation note: this is a @newtype@ instead of a simple @type
-- Name = ByteString@ alias so we can define a UTF-8 based 'IsString'
-- instance. Non-ASCII users would have a bad time otherwise.
newtype Name = Name { fromName :: ByteString }
  deriving (Eq, Ord, Semigroup, Show)

instance IsString Name where
  fromString = Name . Utf8.fromString
  {-# INLINABLE fromString #-}
