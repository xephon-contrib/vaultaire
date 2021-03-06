{-# LANGUAGE OverloadedStrings #-}

module TestHelpers
(
    cleanup,
    loadState,
    writePonyDayMap,
    throwJust,
    dayFileA,
    dayFileB,
    dayFileC,
    dayFileD,
    runTestDaemon,
    runTestPool,
    prettyPrint,
    extendedCompound,
    simpleCompound,
    simpleMessage,
    extendedMessage,
    sendTestMsg,
    startTestDaemons,
    cleanupTestEnvironment,
    readObject,
    daemonArgsTest
)
where

import Control.Applicative
import Control.Concurrent
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List.NonEmpty (fromList)
import Data.Maybe
import Network.URI
import Numeric (showHex)
import System.Rados.Monadic
import System.ZMQ4.Monadic
import Vaultaire.Broker
import Vaultaire.Daemon
import Vaultaire.Reader (startReader)
import Vaultaire.RollOver
import Vaultaire.Util
import Vaultaire.Writer (startWriter)

cleanup :: Daemon ()
cleanup = liftPool $ unsafeObjects >>= mapM_ (`runObject` remove)

loadState :: Daemon ()
loadState = do
    writePonyDayMap "02_PONY_simple_days" dayFileA
    writePonyDayMap "02_PONY_extended_days" dayFileB
    refreshOriginDays "PONY"
    updateSimpleLatest "PONY" 0x42
    updateExtendedLatest "PONY" 0x52


dayFileA, dayFileB, dayFileC, dayFileD:: ByteString
dayFileA = "\x00\x00\x00\x00\x00\x00\x00\x00\
           \\x08\x00\x00\x00\x00\x00\x00\x00"

dayFileB = "\x00\x00\x00\x00\x00\x00\x00\x00\
           \\x0f\x00\x00\x00\x00\x00\x00\x00"

dayFileC = "\x00\x00\x00\x00\x00\x00\x00\x00\
           \\x0f\x00\x00\x00\x00\x00\x00\x00\
           \\xff\x00\x00\x00\x00\x00\x00\x00\
           \\xfe\x00\x00\x00\x00\x00\x00\x00"

dayFileD = "\x00\x00\x00\x00\x00\x00\x00\x00\
           \\x08\x00\x00\x00\x00\x00\x00\x00\
           \\x42\x00\x00\x00\x00\x00\x00\x00\
           \\x08\x00\x00\x00\x00\x00\x00\x00"

writePonyDayMap :: ByteString -> ByteString -> Daemon ()
writePonyDayMap oid contents = liftPool $
    runObject oid (writeFull contents)
    >>= throwJust

throwJust :: Monad m => Maybe RadosError -> m ()
throwJust =
    maybe (return ()) (error . show)

runTestDaemon :: String -> Daemon a -> IO a
runTestDaemon brokerURI a =
    join $   flip runDaemon (cleanup >> loadState >> a)
         <$> daemonArgsTest (fromJust $ parseURI brokerURI)
                            Nothing "test"

cleanupTestEnvironment :: IO ()
cleanupTestEnvironment = runTestDaemon "tcp://localhost:1234" (return ())

runTestPool :: Pool a -> IO a
runTestPool = runConnect Nothing (parseConfig "/etc/ceph/ceph.conf")
              . runPool "test"

prettyPrint :: ByteString -> String
prettyPrint = concatMap (`showHex` "") . BS.unpack

extendedCompound, simpleCompound, simpleMessage, extendedMessage :: ByteString

extendedCompound = simpleMessage `BS.append` extendedMessage

simpleCompound = simpleMessage `BS.append` simpleMessage

simpleMessage =
    "\x04\x00\x00\x00\x00\x00\x00\x00\
    \\x02\x00\x00\x00\x00\x00\x00\x00\
    \\x01\x00\x00\x00\x00\x00\x00\x00"

extendedMessage =
    "\x05\x00\x00\x00\x00\x00\x00\x00\
    \\x02\x00\x00\x00\x00\x00\x00\x00\
    \\x1f\x00\x00\x00\x00\x00\x00\x00\
    \\&This computer is made of warms.\
    \\x05\x00\x00\x00\x00\x00\x00\x00\
    \\x03\x00\x00\x00\x00\x00\x00\x00\
    \\x04\x00\x00\x00\x00\x00\x00\x00\
    \\&Yay!"

sendTestMsg :: IO [ByteString]
sendTestMsg = runZMQ $ do
    s <- socket Dealer
    connect s "tcp://localhost:5560"
    -- Simulate a client sending a sequence number and message
    sendMulti s $ fromList ["PONY", extendedCompound]
    receiveMulti s

startTestDaemons :: MVar () -> IO ()
startTestDaemons shutdown = do
    linkThread $ do
        runZMQ $ startProxy (Router,"tcp://*:5560")
                            (Dealer,"tcp://*:5561")
                            "tcp://*:5000"
        readMVar shutdown

    linkThread $ do
        runZMQ $ startProxy (Router,"tcp://*:5570")
                            (Dealer,"tcp://*:5571")
                            "tcp://*:5001"
        readMVar shutdown

    argsw <- daemonArgsDefault (fromJust $ parseURI "tcp://localhost:5561")
                               Nothing "test" shutdown
    argsr <- daemonArgsDefault (fromJust $ parseURI "tcp://localhost:5571")
                               Nothing "test" shutdown

    linkThread $ startWriter argsw 0
    linkThread $ startReader argsr

readObject :: ByteString -> IO (Either RadosError ByteString)
readObject = runTestPool . flip runObject readFull

daemonArgsTest :: URI -> Maybe String -> String -> IO DaemonArgs
daemonArgsTest broker_uri user pool = do
    x <- newEmptyMVar
    daemonArgsDefault broker_uri user pool x
