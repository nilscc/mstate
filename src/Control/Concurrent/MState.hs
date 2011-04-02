{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, UndecidableInstances,
             ScopedTypeVariables #-}

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
    , module Control.Monad.State.Class
    , runMState
    , evalMState
    , execMState
    , mapMState
    -- , withMState
    , modifyM
    , modifyM_

      -- * Concurrency
    , Forkable (..)
    , forkM
    , forkM_
    , killMState

      -- * Example
      -- $example
    ) where

import Prelude hiding (catch)

import Control.Monad.State.Class
import Control.Monad.Cont
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.Writer

import Control.Concurrent
import Control.Concurrent.STM

import Control.Monad.IO.Peel
import Control.Exception.Peel
import Control.Monad.Trans.Peel


-- | The MState monad is a state monad for concurrent applications. To create a
-- new thread sharing the same (modifiable) state use the `forkM` function.
newtype MState t m a = MState { runMState' :: (TVar t, TVar [(ThreadId, TMVar ())]) -> m a }

-- | Typeclass for forkable monads. This is the basic information about how to
-- fork a new thread in the current monad. To start a new thread in a `MState`
-- application you should always use `forkM`.
class MonadIO m => Forkable m where
    fork :: m () -> m ThreadId

-- | Wait for all `TMVars` to get filled by their processes.
waitForTermination :: MonadIO m
                   => TVar [(ThreadId, TMVar ())]
                   -> m ()
waitForTermination = liftIO . atomically . (mapM_ (takeTMVar . snd) <=< readTVar)

-- | Run a `MState` application, returning both, the function value and the
-- final state. Note that this function has to wait for all threads to finish
-- before it can return the final state.
runMState :: (Forkable m, MonadPeelIO m)
          => MState t m a      -- ^ Action to run
          -> t                 -- ^ Initial state value
          -> m (a,t)
runMState m t = do
  (a, Just t') <- runAndWaitMaybe True m t
  return (a, t')

runAndWaitMaybe :: (Forkable m, MonadPeelIO m)
                => Bool
                -> MState t m a
                -> t
                -> m (a, Maybe t)
runAndWaitMaybe b m t = do

    myI <- liftIO myThreadId
    myM <- liftIO newEmptyTMVarIO
    ref <- liftIO $ newTVarIO t
    c   <- liftIO $ newTVarIO [(myI, myM)]
    a   <- runMState' m (ref, c) `finally` liftIO (atomically $ putTMVar myM ())
    if b then do
      -- wait before getting the final state
      waitForTermination c
      t'  <- liftIO . atomically $ readTVar ref
      return (a, Just t')
     else
      -- don't wait for other threads
      return (a, Nothing)

-- | Run a `MState` application, ignoring the final state. If the first
-- argument is `True` this function will wait for all threads to finish before
-- returning the final result, otherwise it will return the function value as
-- soon as its acquired.
evalMState :: (Forkable m, MonadPeelIO m)
           => Bool              -- ^ Wait for all threads to finish?
           -> MState t m a      -- ^ Action to evaluate
           -> t                 -- ^ Initial state value
           -> m a
evalMState b m t = runAndWaitMaybe b m t >>= return . fst

-- | Run a `MState` application, ignoring the function value. This function
-- will wait for all threads to finish before returning the final state.
execMState :: (Forkable m, MonadPeelIO m)
           => MState t m a      -- ^ Action to execute
           -> t                 -- ^ Initial state value
           -> m t
execMState m t = runMState m t >>= return . snd

-- | Map a stateful computation from one @(return value, state)@ pair to
-- another. See "Control.Monad.State.Lazy" for more information. Be aware that
-- both MStates still share the same state.
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

{- TODO: What's the point of this function? Does it make sense for MStates?

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

-}

-- | Modify the MState, block all other threads from accessing the state in the
-- meantime (using `atomically` from the "Control.Concurrent.STM" library).
modifyM :: MonadIO m => (t -> (a,t)) -> MState t m a
modifyM f = MState $ \(t,_) ->
    liftIO . atomically $ do
        v <- readTVar t
        let (a,v') = f v
        writeTVar t v'
        return a

modifyM_ :: MonadIO m => (t -> t) -> MState t m ()
modifyM_ f = modifyM (\t -> ((), f t))

-- | Start a new thread, using the `fork` function from the `Forkable` type
-- class. When using this function, the main process will wait for all child
-- processes to finish (if desired).
forkM :: (MonadPeelIO m, Forkable m)
      => MState t m ()         -- ^ State action to be forked
      -> MState t m ThreadId
forkM m = MState $ \s@(_,c) -> do

    w <- liftIO newEmptyTMVarIO

    tid <- fork $
      -- Use `finally` to make sure our TMVar gets filled
      runMState' m s `finally` liftIO (atomically $ putTMVar w ())

    -- Add the new thread to our waiting TVar
    liftIO . atomically $ do
        r <- readTVar c
        writeTVar c ((tid,w):r)

    return tid

forkM_ :: (MonadPeelIO m, Forkable m)
       => MState t m ()         -- ^ State action to be forked
       -> MState t m ()
forkM_ m = do
  _ <- forkM m
  return ()

-- | Kill all threads in the current `MState` application.
killMState :: Forkable m => MState t m ()
killMState = MState $ \(_,tv) -> do
    tms <- liftIO . atomically $ readTVar tv
    -- run this in a new thread so it doesn't kill itself
    _ <- liftIO . forkIO $
      mapM_ (killThread . fst) tms
    return ()

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

--------------------------------------------------------------------------------
-- MonadPeel instances
--------------------------------------------------------------------------------

instance MonadTransPeel (MState t) where
    peel = MState $ \t -> return $ \m -> do
        a <- runMState' m t
        return $ return a

instance MonadPeelIO m => MonadPeelIO (MState t m) where
    peelIO = liftPeel peelIO

--------------------------------------------------------------------------------
-- Forkable instances
--------------------------------------------------------------------------------

instance Forkable IO where
    fork = forkIO

instance Forkable m => Forkable (ReaderT s m) where
    fork newT = ask >>= lift . fork . runReaderT newT

instance (Error e, Forkable m) => Forkable (ErrorT e m) where
    fork newT = lift . fork $ runErrorT newT >> return ()

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
>     -- increase in the current thread
>     inc
>     -- This thread should get killed before it can "inc" our state:
>     t_id <- forkM $ do
>         delay 2
>         inc
>     -- Second increase with a small delay in a forked thread, killing the
>     -- thread above
>     forkM $ do
>         delay 1
>         inc
>         kill t_id
>     return ()
>   where
>     inc   = modifyM (+1)
>     kill  = liftIO . killThread
>     delay = liftIO . threadDelay . (*1000000) -- in seconds

-}
