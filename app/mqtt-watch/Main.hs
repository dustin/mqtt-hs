{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad        (void, when)
import qualified Data.ByteString.Lazy as BL
import           Data.Maybe           (fromJust)
import qualified Data.Text.IO         as TIO
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative  (Parser, argument, execParser, fullDesc,
                                       help, helper, info, long, maybeReader,
                                       metavar, option, progDesc, short,
                                       showDefault, some, str, switch, value,
                                       (<**>))
import           System.IO            (stdout)

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

run :: Options -> IO ()
run Options{..} = do
  mc <- connectURI mqttConfig{_msgCB=SimpleCallback showme, _protocol=Protocol50,
                              _connProps=[PropReceiveMaximum 65535,
                                          PropTopicAliasMaximum 10,
                                          PropRequestResponseInformation 1,
                                          PropRequestProblemInformation 1]}
        optUri

  void $ subscribe mc [(t, subOptions) | t <- optTopics] mempty

  print =<< waitForClient mc

    where showme _ t m props = do
            TIO.putStr $ mconcat [t, " → "]
            BL.hPut stdout m
            putStrLn ""
            when (not optHideProps) $ mapM_ (putStrLn . ("  " <>) . drop 4 . show) props

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch stuff.")
