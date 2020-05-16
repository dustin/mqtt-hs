{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (async, link)
import           Control.Concurrent.STM     (TChan, atomically, newTChanIO, readTChan, writeTChan)
import           Control.Exception          (Handler (..), IOException, catches)
import           Control.Monad              (foldM_, forever, when)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BCS
import qualified Data.IORef                 as R
import           Data.Maybe                 (fromJust)
import qualified Data.Text.IO               as TIO
import           Data.Word                  (Word32)
import           Network.MQTT.Client
import           Network.MQTT.Types         (ConnACKFlags (..), SessionReuse (..))
import           Network.URI
import           Options.Applicative        (Parser, argument, auto, execParser, fullDesc, help, helper, info, long,
                                             maybeReader, metavar, option, progDesc, short, showDefault, some, str,
                                             switch, value, (<**>))
import           System.IO                  (stdout)

data Msg = Msg Topic BL.ByteString [Property]

data Options = Options {
  optUri           :: URI
  , optHideProps   :: Bool
  , optSessionTime :: Word32
  , optVerbose     :: Bool
  , optQoS         :: QoS
  , optSubResume   :: Bool
  , optTopics      :: [Topic]
  }

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> short 'u' <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> switch (short 'p' <> help "hide properties")
  <*> option auto (long "session-timeout" <> showDefault <> value 0 <> help "mqtt session timeout (0 == clean)")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (toEnum <$> auto) (long "qos" <> short 'q' <> showDefault <> value QoS0 <> help "QoS level (0-2)")
  <*> switch (long "always-subscribe" <> help "subscribe even when resuming a connection")
  <*> some (argument str (metavar "topics..."))

printer :: TChan Msg -> Bool -> IO ()
printer ch showProps = forever $ do
  (Msg t m props) <- atomically $ readTChan ch
  TIO.putStr $ mconcat [t, " → "]
  BL.hPut stdout m
  putStrLn ""
  when showProps $ mapM_ (putStrLn . ("  " <>) . drop 4 . show) props

run :: Options -> IO ()
run Options{..} = do
  ch <- newTChanIO
  async (printer ch (not optHideProps)) >>= link
  uref <- R.newIORef optUri

  forever $ catches (go ch uref) [Handler (\(ex :: MQTTException) -> handler (show ex)),
                                  Handler (\(ex :: IOException) -> handler (show ex))]

  where
    go ch uref = do
      uri <- R.readIORef uref
      when optVerbose $ putStrLn ("Connecting to " <> show uri)
      mc <- connectURI mqttConfig{_msgCB=SimpleCallback (showme ch), _protocol=Protocol50,
                                  _cleanSession=optSessionTime == 0,
                                  _connProps=[PropReceiveMaximum 65535,
                                              PropTopicAliasMaximum 10000,
                                              PropSessionExpiryInterval optSessionTime,
                                              PropRequestResponseInformation 1,
                                              PropRequestProblemInformation 1]}
        uri

      (ConnACKFlags sp _ props) <- connACK mc
      when (optSessionTime > 0) $ updateURI uref props
      when optVerbose $ putStrLn (if sp == ExistingSession then "<resuming session>" else "<new session>")
      when optVerbose $ putStrLn ("Properties: " <> show props)
      when (sp == NewSession || optSubResume) $ do
        subres <- subscribe mc [(t, subOptions{_subQoS=optQoS}) | t <- optTopics] mempty
        when optVerbose $ print subres

      print =<< waitForClient mc

    showme ch _ t m props = atomically $ writeTChan ch $ Msg t m props

    handler e = putStrLn ("ERROR: " <> e) >> threadDelay 1000000

    updateURI uref = foldM_ up ()
      where up _ (PropAssignedClientIdentifier i) = R.modifyIORef uref (\u -> u{uriFragment='#':BCS.unpack i})
            up a _ = pure a

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch stuff.")
