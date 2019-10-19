{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM   (TChan, atomically, newTChanIO,
                                           readTChan, writeTChan)
import           Control.Exception        (Handler (..), IOException, catches)
import           Control.Monad            (forever, void, when)
import qualified Data.ByteString.Lazy     as BL
import           Data.Maybe               (fromJust)
import qualified Data.Text.IO             as TIO
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative      (Parser, argument, execParser,
                                           fullDesc, help, helper, info, long,
                                           maybeReader, metavar, option,
                                           progDesc, short, showDefault, some,
                                           str, switch, value, (<**>))
import           System.IO                (stdout)

data Msg = Msg Topic BL.ByteString [Property]

data Options = Options {
  optUri         :: URI
  , optHideProps :: Bool
  , optTopics    :: [Topic]
  }

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> short 'u' <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> switch (short 'p' <> help "hide properties")
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

  forever $ catches (go ch) [Handler (\(ex :: MQTTException) -> handler (show ex)),
                             Handler (\(ex :: IOException) -> handler (show ex))]

  where
    go ch = do
      mc <- connectURI mqttConfig{_msgCB=SimpleCallback (showme ch), _protocol=Protocol50,
                                  _connProps=[PropReceiveMaximum 65535,
                                              PropTopicAliasMaximum 10,
                                              PropRequestResponseInformation 1,
                                              PropRequestProblemInformation 1]}
        optUri

      void $ subscribe mc [(t, subOptions) | t <- optTopics] mempty

      print =<< waitForClient mc

    showme ch _ t m props = atomically $ writeTChan ch $ Msg t m props

    handler e = putStrLn ("ERROR: " <> e) >> threadDelay 1000000

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch stuff.")
