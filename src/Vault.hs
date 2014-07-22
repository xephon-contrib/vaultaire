--
-- Data vault for metrics
--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Concurrent.MVar
import Control.Monad
import qualified Data.ByteString.Char8 as S
import Data.Maybe (fromJust)
import Data.String
import Data.Word (Word64)
import GHC.Conc
import Options.Applicative hiding (Parser, option)
import qualified Options.Applicative as O
import System.Directory
import System.IO (hFlush, hPutStr, stdout)
import System.Log.Handler.Syslog
import System.Log.Logger
import System.Posix.Signals
import Text.Trifecta

import CommandRunners
import DaemonRunners
import Marquise.Client


data Options = Options
  { pool      :: String
  , user      :: String
  , broker    :: String
  , debug     :: Bool
  , component :: Component }

data Component = Broker
               | Reader
               | Writer { bucketSize :: Word64 }
               | Marquise { origin :: Origin, namespace :: String }
               | Contents
               | RegisterOrigin { origin  :: Origin
                                , buckets :: Word64
                                , step    :: Word64
                                , begin   :: Word64
                                , end     :: Word64 }
               | Read { origin  :: Origin
                      , address :: Address
                      , start   :: Word64
                      , end     :: Word64 }
               | List { origin :: Origin }
               | DumpDays { origin :: Origin }

-- | Command line option parsing

helpfulParser :: Options -> O.ParserInfo Options
helpfulParser os = info (helper <*> optionsParser os) fullDesc

optionsParser :: Options -> O.Parser Options
optionsParser Options{..} = Options <$> parsePool
                                    <*> parseUser
                                    <*> parseBroker
                                    <*> parseDebug
                                    <*> parseComponents
  where
    parsePool = strOption $
           long "pool"
        <> short 'p'
        <> metavar "POOL"
        <> value pool
        <> showDefault
        <> help "Ceph pool name for storage"

    parseUser = strOption $
           long "user"
        <> short 'u'
        <> metavar "USER"
        <> value user
        <> showDefault
        <> help "Ceph user for access to storage"

    parseBroker = strOption $
           long "broker"
        <> short 'b'
        <> metavar "BROKER"
        <> value broker
        <> showDefault
        <> help "Vault broker host name or IP address"

    parseDebug = switch $
           long "debug"
        <> short 'd'
        <> help "Set log level to DEBUG"

    parseComponents = subparser
       (   parseBrokerComponent
       <> parseReaderComponent
       <> parseWriterComponent
       <> parseMarquiseComponent
       <> parseContentsComponent
       <> parseRegisterOriginComponent
       <> parseReadComponent
       <> parseListComponent
       <> parseDumpDaysComponent )

    parseBrokerComponent =
        componentHelper "broker" (pure Broker) "Start a broker daemon"

    parseReaderComponent =
        componentHelper "reader" (pure Reader) "Start a reader daemon"

    parseWriterComponent =
        componentHelper "writer" writerOptionsParser "Start a writer daemon"

    parseMarquiseComponent =
        componentHelper "marquise" marquiseOptionsParser "Start a marquise daemon"

    parseContentsComponent =
        componentHelper "contents" (pure Contents) "Start a contents daemon"

    parseRegisterOriginComponent =
        componentHelper "register" registerOriginParser "Register a new origin"

    parseReadComponent =
        componentHelper "read" readOptionsParser "Read points"

    parseListComponent =
        componentHelper "list" listOptionsParser "List addresses and metadata in origin"

    parseDumpDaysComponent =
        componentHelper "days" dumpDaysParser "Display the current day map contents"

    componentHelper cmd_name parser desc =
        command cmd_name (info (helper <*> parser) (progDesc desc))

parseOrigin :: O.Parser Origin
parseOrigin = argument (fmap mkOrigin . str) (metavar "ORIGIN")
  where
    mkOrigin = Origin . S.pack

readOptionsParser :: O.Parser Component
readOptionsParser = Read <$> parseOrigin
                         <*> parseAddress
                         <*> parseStart
                         <*> parseEnd
  where
    parseAddress = argument (fmap fromString . str) (metavar "ADDRESS")
    parseStart = O.option $
        long "start"
        <> short 's'
        <> value 0
        <> showDefault
        <> help "Start time in nanoseconds since epoch"

    parseEnd = O.option $
        long "end"
        <> short 'e'
        <> value maxBound
        <> showDefault
        <> help "End time in nanoseconds since epoch"

listOptionsParser :: O.Parser Component
listOptionsParser = List <$> parseOrigin

dumpDaysParser :: O.Parser Component
dumpDaysParser = DumpDays <$> parseOrigin

registerOriginParser :: O.Parser Component
registerOriginParser = RegisterOrigin <$> parseOrigin
                                      <*> parseBuckets
                                      <*> parseStep
                                      <*> parseBegin
                                      <*> parseEnd
  where
    parseBuckets = O.option $
        long "buckets"
        <> short 'n'
        <> value 128
        <> showDefault
        <> help "Number of buckets to distribute writes over"

    parseStep = O.option $
        long "step"
        <> short 's'
        <> value 14400000000000
        <> showDefault
        <> help "Back-dated rollover period (see documentation: TODO)"

    parseBegin = O.option $
        long "begin"
        <> short 'b'
        <> value 0
        <> showDefault
        <> help "Back-date begin time (default is no backdating)"

    parseEnd = O.option $
        long "end"
        <> short 'e'
        <> value 0
        <> showDefault
        <> help "Back-date end time"

writerOptionsParser :: O.Parser Component
writerOptionsParser = Writer <$> parseBucketSize
  where
    parseBucketSize = O.option $
        long "roll_over_size"
        <> short 'r'
        <> value 4194304
        <> showDefault
        <> help "Maximum bytes in any given bucket before rollover"

marquiseOptionsParser :: O.Parser Component
marquiseOptionsParser = Marquise <$> parseOrigin <*> parseNameSpace
  where
    parseNameSpace = strOption $
        long "namespace"
        <> short 'n'
        <> metavar "NAMESPACE"
        <> help "NameSpace to look for data in"

-- | Config file parsing
parseConfig :: FilePath -> IO Options
parseConfig fp = do
    exists <- doesFileExist fp
    if exists
        then do
            maybe_ls <- parseFromFile configParser fp
            case maybe_ls of
                Just ls -> return $ mergeConfig ls defaultConfig
                Nothing  -> error "Failed to parse config"
        else return defaultConfig
  where
    defaultConfig = Options "vaultaire" "vaultaire" "localhost" False Broker
    mergeConfig ls Options{..} = fromJust $
        Options <$> lookup "pool" ls `mplus` pure pool
                <*> lookup "user" ls `mplus` pure user
                <*> lookup "broker" ls `mplus` pure broker
                <*> pure debug
                <*> pure Broker

configParser :: Parser [(String, String)]
configParser = some $ liftA2 (,)
    (spaces *> possibleKeys <* spaces <* char '=')
    (spaces *> (stringLiteral <|> stringLiteral'))

possibleKeys :: Parser String
possibleKeys =
        string "pool"
    <|> string "user"
    <|> string "broker"

parseArgsWithConfig :: FilePath -> IO Options
parseArgsWithConfig = parseConfig >=> execParser . helpfulParser

--
-- Main program entry point
--

interruptHandler :: MVar () -> Handler
interruptHandler semaphore = Catch $ do
    hPutStr stdout "\n"
    hFlush stdout
    warningM "Main.interruptHandler" "Interrupted"
    putMVar semaphore ()

terminateHandler :: MVar () -> Handler
terminateHandler semaphore = Catch $ do
    infoM "Main.terminateHandler" "Terminated"
    putMVar semaphore ()

quitHandler :: Handler
quitHandler = Catch $ do
    hPutStr stdout "\n"
    hFlush stdout
    logger <- getLogger rootLoggerName
    let level   = getLevel logger
        level'  = case level of
                    Just DEBUG  -> INFO
                    Just INFO   -> DEBUG
                    _           -> DEBUG
        logger' = setLevel level' logger
    saveGlobalLogger logger'
    infoM "Main.quitHandler" ("Change log level to " ++ show level')

main :: IO ()
main = do
    -- command line +RTS -Nn -RTS value
    when (numCapabilities == 1) (getNumProcessors >>= setNumCapabilities)

    quit <- newEmptyMVar

    _ <- installHandler sigINT  (interruptHandler quit) Nothing
    _ <- installHandler sigTERM (terminateHandler quit) Nothing
    _ <- installHandler sigQUIT (quitHandler) Nothing

    Options{..} <- parseArgsWithConfig "/etc/vaultaire.conf"

    -- Start and configure logger
    let level = if debug then DEBUG else INFO
    logger <- openlog "vaultaire" [PID] USER level
    updateGlobalLogger rootLoggerName (addHandler logger . setLevel level)

    debugM "Main.main" "Logger initialized, starting component"

    -- Run daemons and/or commands. These are all expected to fork threads and
    -- return. If termination is requested, then they have to put unit into the
    -- shutdown MVar.

    case component of
        Broker ->
            runBrokerDaemon quit
        Reader ->
            runReaderDaemon pool user broker quit
        Writer roll_over_size ->
            runWriterDaemon pool user broker roll_over_size quit
        Marquise origin namespace ->
            runMarquiseDaemon broker origin namespace quit
        Contents ->
            runContentsDaemon pool user broker quit
        RegisterOrigin origin buckets step begin end ->
            runRegisterOrigin pool user origin buckets step begin end quit
        Read origin addr start end ->
            runReadPoints broker origin addr start end quit
        List origin ->
            runListContents broker origin quit
        DumpDays origin ->
            runDumpDayMap pool user origin quit

    -- Block until shutdown triggered
    debugM "Main.main" "Running until shutdown"
    _ <- readMVar quit
    debugM "Main.main" "End"

