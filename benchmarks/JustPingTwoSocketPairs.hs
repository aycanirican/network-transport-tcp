{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Control.Monad

import Data.Int
import Network.Socket
  ( AddrInfo, AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr, NoDelay)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , defaultHints
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import System.Environment (getArgs, withArgs)
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.IO (withFile, IOMode(..), hPutStrLn, Handle, stderr)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import qualified Network.Socket as N
import Debug.Trace
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack, unpack)
import qualified Data.ByteString as BS
import qualified Network.Socket.ByteString as NBS
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import Data.ByteString.Internal as BSI
import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.C (CInt(..))
import Foreign.ForeignPtr (withForeignPtr)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)

foreign import ccall unsafe "htonl" htonl :: CInt -> CInt
foreign import ccall unsafe "ntohl" ntohl :: CInt -> CInt

passive :: Maybe AddrInfo
passive = Just (defaultHints { addrFlags = [AI_PASSIVE] })

main = do
  pingsStr:args <- getArgs
  serverReady   <- newEmptyMVar
  clientReady   <- newEmptyMVar
  clientDone    <- newEmptyMVar

  -- Start the server
  forkIO $ do
    -- Initialize the server
    serverAddr:_ <- getAddrInfo passive Nothing (Just "8080")
    sock         <- socket (addrFamily serverAddr) Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (addrAddress serverAddr)
    listen sock 1

    -- Set up multiplexing channel
    multiplexChannel <- newChan

    -- Connect to the client (to reply)
    forkIO $ do
      takeMVar clientReady
      clientAddr:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "8081")
      pongSock     <- socket (addrFamily clientAddr) Stream defaultProtocol
      N.connect pongSock (addrAddress clientAddr)
      when ("--NoDelay" `elem` args) $ setSocketOption pongSock NoDelay 1
      forever $ readChan multiplexChannel >>= send pongSock 

    -- Wait for incoming connections (pings from the client)
    putMVar serverReady ()
    (pingSock, pingAddr) <- accept sock
    socketToChan pingSock multiplexChannel

  -- Start the client
  forkIO $ do
    clientAddr:_ <- getAddrInfo passive Nothing (Just "8081")
    sock         <- socket (addrFamily clientAddr) Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (addrAddress clientAddr)
    listen sock 1

    -- Set up multiplexing channel
    multiplexChannel <- newChan

    -- Connect to the server (to send pings)
    forkIO $ do
      takeMVar serverReady
      serverAddr:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "8080")
      pingSock     <- socket (addrFamily serverAddr) Stream defaultProtocol
      N.connect pingSock (addrAddress serverAddr)
      when ("--NoDelay" `elem` args) $ setSocketOption pingSock NoDelay 1
      ping pingSock multiplexChannel (read pingsStr)
      putMVar clientDone ()

    -- Wait for incoming connections (pongs from the server)
    putMVar clientReady () 
    (pongSock, pongAddr) <- accept sock
    socketToChan pongSock multiplexChannel

  -- Wait for the client to finish
  takeMVar clientDone

socketToChan :: Socket -> Chan ByteString -> IO ()
socketToChan sock chan = go
  where
    go = do bs <- recv sock
            when (BS.length bs > 0) $ do
               writeChan chan bs
               go

pingMessage :: ByteString
pingMessage = pack "ping123"

ping :: Socket -> Chan ByteString -> Int -> IO () 
ping sock chan pings = go pings
  where
    go :: Int -> IO ()
    go 0 = do 
      putStrLn $ "client did " ++ show pings ++ " pings"
    go !i = do
      before <- getCurrentTime
      send sock pingMessage 
      bs <- readChan chan  
      after <- getCurrentTime
      -- putStrLn $ "client received " ++ unpack bs
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      hPutStrLn stderr $ show i ++ " " ++ show latency 
      go (i - 1)

-- | Receive a package 
recv :: Socket -> IO ByteString
recv sock = do
  header <- NBS.recv sock 4
  length <- decodeLength header 
  NBS.recv sock (fromIntegral (length :: Int32))

-- | Send a package
send :: Socket -> ByteString -> IO () 
send sock bs = do
  length <- encodeLength (fromIntegral (BS.length bs))
  NBS.sendMany sock [length, bs]

-- | Encode length (manual for now)
encodeLength :: Int32 -> IO ByteString
encodeLength i32 = 
  BSI.create 4 $ \p ->
    pokeByteOff p 0 (htonl (fromIntegral i32))

-- | Decode length (manual for now)
decodeLength :: ByteString -> IO Int32
decodeLength bs = 
  let (fp, _, _) = BSI.toForeignPtr bs in 
  withForeignPtr fp $ \p -> do
    w32 <- peekByteOff p 0 
    return (fromIntegral (ntohl w32))
