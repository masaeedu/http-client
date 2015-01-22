{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Network.HTTP.Client.Util
    ( hGetSome
    , (<>)
    , readDec
    , hasNoBody
    , fromStrict
    , timeout
    ) where

import Data.Monoid (Monoid, mappend)

import qualified Data.ByteString.Char8 as S8
#if MIN_VERSION_bytestring(0,10,0)
import Data.ByteString.Lazy (fromStrict)
#else
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString as S
#endif

import qualified Data.Text as T
import qualified Data.Text.Read

import qualified GHC.Event as E
import Control.Exception (throwTo, bracket, Exception, throwIO, IOException, handle)
import Control.Concurrent (myThreadId)
import qualified System.Timeout as T
import System.IO.Unsafe (unsafePerformIO)

#if MIN_VERSION_base(4,3,0)
import Data.ByteString (hGetSome)
#else
import GHC.IO.Handle.Types
import System.IO                (hWaitForInput, hIsEOF)
import System.IO.Error          (mkIOError, illegalOperationErrorType)

-- | Like 'hGet', except that a shorter 'ByteString' may be returned
-- if there are not enough bytes immediately available to satisfy the
-- whole request.  'hGetSome' only blocks if there is no data
-- available, and EOF has not yet been reached.
hGetSome :: Handle -> Int -> IO S.ByteString
hGetSome hh i
    | i >  0    = let
                   loop = do
                     s <- S.hGetNonBlocking hh i
                     if not (S.null s)
                        then return s
                        else do eof <- hIsEOF hh
                                if eof then return s
                                       else hWaitForInput hh (-1) >> loop
                                         -- for this to work correctly, the
                                         -- Handle should be in binary mode
                                         -- (see GHC ticket #3808)
                  in loop
    | i == 0    = return S.empty
    | otherwise = illegalBufferSize hh "hGetSome" i

illegalBufferSize :: Handle -> String -> Int -> IO a
illegalBufferSize handle fn sz =
    ioError (mkIOError illegalOperationErrorType msg (Just handle) Nothing)
    --TODO: System.IO uses InvalidArgument here, but it's not exported :-(
    where
      msg = fn ++ ": illegal ByteString size " ++ showsPrec 9 sz []
#endif

infixr 5 <>
(<>) :: Monoid m => m -> m -> m
(<>) = mappend

readDec :: Integral i => String -> Maybe i
readDec s =
    case Data.Text.Read.decimal $ T.pack s of
        Right (i, t)
            | T.null t -> Just i
        _ -> Nothing

hasNoBody :: S8.ByteString -- ^ request method
          -> Int -- ^ status code
          -> Bool
hasNoBody "HEAD" _ = True
hasNoBody _ 204 = True
hasNoBody _ 304 = True
hasNoBody _ i = 100 <= i && i < 200

#if !MIN_VERSION_bytestring(0,10,0)
{-# INLINE fromStrict #-}
fromStrict :: S.ByteString -> L.ByteString
fromStrict x = L.fromChunks [x]
#endif

timeout :: Exception e => e -> Int -> IO a -> IO a
timeout e usec action = do
    -- It would be nice if there was a non-partial version of
    -- E.getSystemTimerManager...
    timeout' <- handle (\(_ :: IOException) -> return timeoutST) $ do
        tm <- E.getSystemTimerManager
        return $ timeoutMT tm
    timeout' e usec action

-- | Single threaded
timeoutST :: Exception e => e -> Int -> IO a -> IO a
timeoutST e usec action =
    T.timeout usec action >>= maybe (throwIO e) return

-- | Multi threaded
--timeoutMT :: Exception e => E.TimerManager -> e -> Int -> IO a -> IO a
timeoutMT man e usec action = do
    tid <- myThreadId
    bracket
        (E.registerTimeout
            man
            usec
            -- FIXME should we forkIO the call to throwTo to avoid
            -- being blocked by a masked thread?
            (throwTo tid e))
        (E.unregisterTimeout man)
        (const action)
