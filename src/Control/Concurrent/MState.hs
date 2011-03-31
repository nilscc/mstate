{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}

---------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.MState
-- Copyright   :  (c) Nils Schweinsberg 2010
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  mail@n-sch.de
-- Stability   :  unstable
-- Portability :  portable
--
-- MState: A consistent state monad for concurrent applications.
--
---------------------------------------------------------------------------

module Control.Concurrent.MState
    ( 
      -- * The MState Monad
      MState
    , runMState
    , evalMState
    , execMState
    , mapMState
    , withMState
    , modifyM

      -- * Concurrency
    , Forkable (..)
    , forkM

      -- * Example
      -- $example
    ) where


import Control.Monad.State.Class
import Control.Monad.Cont
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.Writer

import Control.Concurrent
import Control.Concurrent.STM

import Control.Monad.IO.Peel
import Control.Exception.Peel


-- | The MState is an abstract data definition for a State monad which can be
-- used in concurrent applications. Use `forkM` to start a new thread with the
-- same state.
newtype MState t m a = MState { runMState' :: (TVar t, TVar [TMVar ()]) -> m a }


-- | Typeclass for forkable monads, for instance:
--
-- > instance Forkable IO where
-- >   fork = forkIO
--
-- This is only the basic information about how to fork a new thread in the
-- current monad. To start a new thread in a `MState` application you should
-- always use `forkM`.
class (MonadPeelIO m) => Forkable m where
    fork :: m () -> m ThreadId

instance Forkable IO where
    fork = forkIO

instance Forkable (ReaderT s IO) where
    fork newT = ask >>= liftIO . forkIO . runReaderT newT


-- | Wait for all `TMVars` to get filled by their processes
waitForTermination :: MonadIO m
                   => TVar [TMVar ()]
                   -> m ()
waitForTermination = liftIO . atomically . (mapM_ takeTMVar <=< readTVar)

-- | Run a `MState` application,  returning both, the function value and the
-- final state
runMState :: Forkable m
           => MState t m a      -- ^ Action to run
           -> t                 -- ^ Initial state value
           -> m (a,t)
runMState m t = do

    ref <- liftIO $ newTVarIO t
    c   <- liftIO $ newTVarIO []
    mv  <- liftIO newEmptyMVar

    _  <- runMState' (forkM $ m >>= liftIO . putMVar mv) (ref, c)

    waitForTermination c
    a  <- liftIO $ takeMVar mv
    t' <- liftIO . atomically $ readTVar ref
    return (a,t')


-- | Run a `MState` application, ignoring the final state
evalMState :: Forkable m
           => MState t m a      -- ^ Action to evaluate
           -> t                 -- ^ Initial state value
           -> m a
evalMState m t = runMState m t >>= return . fst


-- | Run a `MState` application, ignoring the function value
execMState :: Forkable m
           => MState t m a      -- ^ Action to execute
           -> t                 -- ^ Initial state value
           -> m t
execMState m t = runMState m t >>= return . snd


-- | Map a stateful computation from one @(return value, state)@ pair to
-- another. See "Control.Monad.State.Lazy" for more information.
mapMState :: (MonadIO m, MonadIO n)
          => (m (a,t) -> n (b,t))
          -> MState t m a
          -> MState t n b
mapMState f m = MState $ \s@(r,_) -> do
    ~(b,v') <- f $ do
        a <- runMState' m s
        v <- liftIO . atomically $ readTVar r
        return (a,v)
    liftIO . atomically $ writeTVar r v'
    return b


-- | Apply a function to the state before running the `MState`
withMState :: (MonadIO m)
           => (t -> t)
           -> MState t m a
           -> MState t m a
withMState f m = MState $ \s@(r,_) -> do
    liftIO . atomically $ do
        v <- readTVar r
        writeTVar r (f v)
    runMState' m s



-- | Modify the MState, block all other threads from accessing the state in the
-- meantime.
modifyM :: (MonadIO m) => (t -> t) -> MState t m ()
modifyM f = MState $ \(t,_) ->
    liftIO . atomically $ do
        v <- readTVar t
        writeTVar t (f v)


-- | Start a new thread, using the `fork` function from the `Forkable` type
-- class. When using this function, the main process will wait for all child
-- processes to finish.
forkM :: Forkable m
      => MState t m ()         -- ^ State action to be forked
      -> MState t m ThreadId
forkM m = MState $ \s@(_,c) -> do

    -- Add new thread MVar to our waiting channel
    w <- liftIO newEmptyTMVarIO
    liftIO . atomically $ do
        r <- readTVar c
        writeTVar c (w:r)

    -- Use `finally` to make sure our TMVar gets filled
    fork $
      runMState' m s `finally` liftIO (atomically $ putTMVar w ())


--------------------------------------------------------------------------------
-- Monad instances
--------------------------------------------------------------------------------

instance (Monad m) => Monad (MState t m) where
    return a = MState $ \_ -> return a
    m >>= k  = MState $ \t -> do
        a <- runMState' m t
        runMState' (k a) t
    fail str = MState $ \_ -> fail str

instance (Monad m) => Functor (MState t m) where
    fmap f m = MState $ \t -> do
        a <- runMState' m t
        return (f a)

instance (MonadPlus m) => MonadPlus (MState t m) where
    mzero       = MState $ \_       -> mzero
    m `mplus` n = MState $ \t -> runMState' m t `mplus` runMState' n t

instance (MonadIO m) => MonadState t (MState t m) where
    get     = MState $ \(r,_) -> liftIO . atomically $ readTVar r
    put val = MState $ \(r,_) -> liftIO . atomically $ writeTVar r val

instance (MonadFix m) => MonadFix (MState t m) where
    mfix f = MState $ \s -> mfix $ \a -> runMState' (f a) s


--------------------------------------------------------------------------------
-- mtl instances
--------------------------------------------------------------------------------

instance MonadTrans (MState t) where
    lift m = MState $ \_ -> m

instance (MonadIO m) => MonadIO (MState t m) where
    liftIO = lift . liftIO

instance (MonadCont m) => MonadCont (MState t m) where
    callCC f = MState $ \s ->
        callCC $ \c ->
            runMState' (f (\a -> MState $ \_ -> c a)) s

instance (MonadError e m) => MonadError e (MState t m) where
    throwError       = lift . throwError
    m `catchError` h = MState $ \s ->
        runMState' m s `catchError` \e -> runMState' (h e) s

instance (MonadReader r m) => MonadReader r (MState t m) where
    ask       = lift ask
    local f m = MState $ \s -> local f (runMState' m s)

instance (MonadWriter w m) => MonadWriter w (MState t m) where
    tell     = lift . tell
    listen m = MState $ listen . runMState' m
    pass   m = MState $ pass   . runMState' m


{- $example

Example usage:

> import Control.Concurrent
> import Control.Concurrent.MState
> import Control.Monad.State
> 
> type MyState a = MState Int IO a
> 
> -- Expected state value: 2
> main :: IO ()
> main = print =<< execMState incTwice 0
> 
> incTwice :: MyState ()
> incTwice = do
> 
>     -- First increase in the current thread
>     inc
>     -- This thread should get killed before it can "inc" our state:
>     kill =<< forkM incDelayed
>     -- Second increase with a small delay in a forked thread
>     forkM incDelayed
> 
>     return ()
> 
>   where
>     inc        = modifyM (+1)
>     kill       = liftIO . killThread
>     incDelayed = do liftIO $ threadDelay 2000000
>                     inc

-}
