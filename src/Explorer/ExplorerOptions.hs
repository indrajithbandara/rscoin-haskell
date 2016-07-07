-- | Command line options for Explorer

module ExplorerOptions
       ( Options (..)
       , getOptions
       ) where

import           Options.Applicative    (Parser, auto, execParser, fullDesc,
                                         help, helper, info, long, metavar,
                                         option, progDesc, short, showDefault,
                                         value, (<>))
import           Serokell.Util.OptParse (strOption)

import           RSCoin.Core            (Severity (Error), defaultPort,
                                         defaultSecretKeyPath)

data Options = Options
    { cloPort          :: Int
    , cloPath          :: FilePath
    , cloSecretKeyPath :: FilePath
    , cloLogSeverity   :: Severity
    }

optionsParser :: FilePath -> Parser Options
optionsParser defaultSKPath =
    Options <$>
    option
        auto
        (mconcat [short 'p', long "port", value defaultPort, showDefault]) <*>
    strOption
        (mconcat
             [ long "path"
             , value "explorer-db"
             , showDefault
             , help "Path to database"]) <*>
    strOption
        (mconcat
             [long "sk", value defaultSKPath, metavar "FILEPATH", showDefault]) <*>
    option
        auto
        (mconcat
             [ long "log-severity"
             , value Error
             , showDefault
             , help "Logging severity"])

getOptions :: IO Options
getOptions = do
    defaultSKPath <- defaultSecretKeyPath
    execParser $
        info
            (helper <*> optionsParser defaultSKPath)
            (fullDesc <> progDesc "RSCoin Block Explorer")