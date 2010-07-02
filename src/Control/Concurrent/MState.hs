{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}

module Control.Concurrent.MState
    ( 
      -- * The MState Monad
      MState

    , evalMState
    , execMState
    , mapMState
    , withMState

      -- * Concurrency
    , Forkable (..)
    , forkM

      -- * Example
      -- $example
    ) where

import Control.Monad
import Control.Monad.State.Class
import Control.Monad.Trans

import Control.Concurrent
import Data.IORef

import qualified Control.Exception as E

-- | The MState is an abstract data definition for a State monad which can be
-- used in concurrent applications. It can be accessed with @evalMState@ and
-- @execMState@. To start a new state thread use @forkM@.
newtype MState t m a = MState { runMState :: (IORef t, Chan (MVar ())) -> m a }


-- | The class which is needed to start new threads in the MState monad. Don't
-- confuse this with @forkM@ which should be used to fork new threads!
class (MonadIO m) => Forkable m where
    fork :: m () -> m ThreadId

instance Forkable IO where
    fork = forkIO


catchMVar :: IO a -> (E.BlockedIndefinitelyOnMVar -> IO a) -> IO a
catchMVar = E.catch


-- | Read the Chan full of MVars and wait for all MVars to get filled by the
-- threads. On MVar-exception this will skip the current MVar and take the next
-- one (if available).
waitForTermination :: MonadIO m
                   => Chan (MVar ())
                   -> m ()
waitForTermination c = liftIO $ do
    empty <- isEmptyChan c
    catchMVar (unless empty $ do -- Read next threads MVar and wait until it's filled
                                 mv <- readChan c
                                 _  <- takeMVar mv
                                 waitForTermination c)
              (const $ return ())


-- | Evaluate the MState monad with the given initial state, throwing away the
-- final state stored in the MVar.
evalMState :: Forkable m
           => MState t m a      -- ^ Action to evaluate
           -> t                 -- ^ Initial state value
           -> m a
evalMState m t = do

    ref <- liftIO $ newIORef t
    c   <- liftIO newChan
    amv <- liftIO newEmptyMVar

    -- Start new state thread
    _   <- runMState (forkM $ m >>= liftIO . putMVar amv) (ref, c)
    -- waitForTermination c

    -- Return m's value
    liftIO $ readMVar amv


-- | Execute the MState monad with a given initial state. Returns the value of
-- the final state.
execMState :: Forkable m
           => MState t m a      -- ^ Action to execute
           -> t                 -- ^ Initial state value
           -> m t
execMState m t = do

    -- Prepare channel & state MVar
    ref <- liftIO $ newIORef t
    c   <- liftIO newChan

    _   <- runMState (forkM $ m >> return ()) (ref, c)
    waitForTermination c

    -- Return state
    liftIO $ readIORef ref


-- | Map a stateful computation from one @(return value, state)@ pair to
-- another. See @Control.Monad.State.Lazy.mapState@ for more information.
mapMState :: (MonadIO m, MonadIO n)
          => (m (a,t) -> n (b,t))
          -> MState t m a
          -> MState t n b
mapMState f m = MState $ \s@(r,_) -> do
    ~(b,v') <- f $ do
        a <- runMState m s
        v <- liftIO $ readIORef r
        return (a,v)
    liftIO $ writeIORef r v'
    return b


-- | Apply this function to this state and return the resulting state.
withMState :: (MonadIO m)
           => (t -> t)
           -> MState t m a
           -> MState t m a
withMState f m = MState $ \s@(r,_) -> do
    liftIO $ modifyIORef r f
    runMState m s


-- | Start a new thread, using @forkIO@. The main process will wait for all
-- child processes to finish.
forkM :: Forkable m
      => MState t m ()         -- ^ State action to be forked
      -> MState t m ThreadId
forkM m = MState $ \s@(_,c) -> do

    -- Add new thread MVar to our waiting channel
    w <- liftIO newEmptyMVar
    liftIO $ writeChan c w
    fork $ runMState m s >> liftIO (putMVar w ())


--------------------------------------------------------------------------------
-- Monad instances
--------------------------------------------------------------------------------

instance (Monad m) => Monad (MState t m) where
    return a = MState $ \_ -> return a
    m >>= k  = MState $ \t -> do
        a <- runMState m t
        runMState (k a) t
    fail str = MState $ \_ -> fail str

instance (Monad m) => Functor (MState t m) where
    fmap f m = MState $ \t -> do
        a <- runMState m t
        return (f a)

instance (MonadPlus m) => MonadPlus (MState t m) where
    mzero       = MState $ \_       -> mzero
    m `mplus` n = MState $ \t -> runMState m t `mplus` runMState n t

instance (MonadIO m) => MonadState t (MState t m) where
    get     = MState $ \(r,_) -> liftIO $ readIORef r
    put val = MState $ \(r,_) -> liftIO $ writeIORef r val

instance MonadTrans (MState t) where
    lift m = MState $ \_ -> m

instance (MonadIO m) => MonadIO (MState t m) where
    liftIO = lift . liftIO



{- $example

Example usage:

> import Control.Concurrent
> import Control.Concurrent.MState
> import Control.Monad.State
> 
> type MyState a = MState Int IO a
> 
> -- Expected state value: 2
> main = print =<< execMState incTwice 0
> 
> incTwice :: MyState ()
> incTwice = do
> 
>     -- First inc
>     inc
> 
>     -- This thread should get killed before it can "inc" our state:
>     kill =<< forkM incDelayed
>     -- This thread should "inc" our state
>     forkM incDelayed
> 
>     return ()
> 
>   where
>     inc        = get >>= put . (+1)
>     kill       = liftIO . killThread
>     incDelayed = do liftIO $ threadDelay 2000000
>                     inc

-}
