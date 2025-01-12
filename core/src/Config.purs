module Spago.Core.Config
  ( BackendConfig
  , WorkspaceBuildOptionsInput
  , CensorBuildWarnings(..)
  , WarningCensorTest(..)
  , StatVerbosity(..)
  , PackageBuildOptionsInput
  , BundleConfig
  , BundlePlatform(..)
  , BundleType(..)
  , Config
  , Dependencies(..)
  , ExtraPackage(..)
  , GitPackage
  , LegacyPackageSetEntry
  , LocalPackage
  , PackageConfig
  , PublishConfig
  , RemotePackage(..)
  , RunConfig
  , SetAddress(..)
  , TestConfig
  , WorkspaceConfig
  , configCodec
  , dependenciesCodec
  , extraPackageCodec
  , gitPackageCodec
  , legacyPackageSetEntryCodec
  , localPackageCodec
  , packageConfigCodec
  , parseBundleType
  , parsePlatform
  , printSpagoRange
  , readConfig
  , remotePackageCodec
  , setAddressCodec
  , widestRange
  ) where

import Spago.Core.Prelude

import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NonEmptyArray
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Codec.Argonaut.Sum as CA.Sum
import Data.Either as Either
import Data.List as List
import Data.Map as Map
import Data.Profunctor as Profunctor
import Partial.Unsafe (unsafeCrashWith)
import Registry.Internal.Codec as Internal.Codec
import Registry.License as License
import Registry.Location as Location
import Registry.PackageName as PackageName
import Registry.Range as Range
import Registry.Sha256 as Sha256
import Registry.Version as Version
import Spago.FS as FS

type Config =
  { package :: Maybe PackageConfig
  , workspace :: Maybe WorkspaceConfig
  }

configCodec :: JsonCodec Config
configCodec = CAR.object "Config"
  { package: CAR.optional packageConfigCodec
  , workspace: CAR.optional workspaceConfigCodec
  }

type PackageConfig =
  { name :: PackageName
  , description :: Maybe String
  , dependencies :: Dependencies
  , build :: Maybe PackageBuildOptionsInput
  , bundle :: Maybe BundleConfig
  , run :: Maybe RunConfig
  , test :: Maybe TestConfig
  , publish :: Maybe PublishConfig
  }

packageConfigCodec :: JsonCodec PackageConfig
packageConfigCodec = CAR.object "PackageConfig"
  { name: PackageName.codec
  , description: CAR.optional CA.string
  , dependencies: dependenciesCodec
  , build: CAR.optional packageBuildOptionsCodec
  , bundle: CAR.optional bundleConfigCodec
  , run: CAR.optional runConfigCodec
  , test: CAR.optional testConfigCodec
  , publish: CAR.optional publishConfigCodec
  }

type PublishConfig =
  { version :: Version
  , license :: License
  , location :: Maybe Location
  , include :: Maybe (Array FilePath)
  , exclude :: Maybe (Array FilePath)
  }

publishConfigCodec :: JsonCodec PublishConfig
publishConfigCodec = CAR.object "PublishConfig"
  { version: Version.codec
  , license: License.codec
  , location: CAR.optional Location.codec
  , include: CAR.optional (CA.array CA.string)
  , exclude: CAR.optional (CA.array CA.string)
  }

type RunConfig =
  { main :: Maybe String
  , execArgs :: Maybe (Array String)
  }

runConfigCodec :: JsonCodec RunConfig
runConfigCodec = CAR.object "RunConfig"
  { main: CAR.optional CA.string
  , execArgs: CAR.optional (CA.array CA.string)
  }

type TestConfig =
  { main :: String
  , execArgs :: Maybe (Array String)
  , dependencies :: Dependencies
  , censor_test_warnings :: Maybe CensorBuildWarnings
  , strict :: Maybe Boolean
  , pedantic_packages :: Maybe Boolean
  }

testConfigCodec :: JsonCodec TestConfig
testConfigCodec = CAR.object "TestConfig"
  { main: CA.string
  , execArgs: CAR.optional (CA.array CA.string)
  , dependencies: dependenciesCodec
  , censor_test_warnings: CAR.optional censorBuildWarningsCodec
  , strict: CAR.optional CA.boolean
  , pedantic_packages: CAR.optional CA.boolean
  }

type BackendConfig =
  { cmd :: String
  , args :: Maybe (Array String)
  }

backendConfigCodec :: JsonCodec BackendConfig
backendConfigCodec = CAR.object "BackendConfig"
  { cmd: CA.string
  , args: CAR.optional (CA.array CA.string)
  }

type PackageBuildOptionsInput =
  { censor_project_warnings :: Maybe CensorBuildWarnings
  , strict :: Maybe Boolean
  , pedantic_packages :: Maybe Boolean
  }

packageBuildOptionsCodec :: JsonCodec PackageBuildOptionsInput
packageBuildOptionsCodec = CAR.object "PackageBuildOptionsInput"
  { censor_project_warnings: CAR.optional censorBuildWarningsCodec
  , strict: CAR.optional CA.boolean
  , pedantic_packages: CAR.optional CA.boolean
  }

type BundleConfig =
  { minify :: Maybe Boolean
  , module :: Maybe String
  , outfile :: Maybe FilePath
  , platform :: Maybe BundlePlatform
  , type :: Maybe BundleType
  , extra_args :: Maybe (Array String)
  }

bundleConfigCodec :: JsonCodec BundleConfig
bundleConfigCodec = CAR.object "BundleConfig"
  { minify: CAR.optional CA.boolean
  , module: CAR.optional CA.string
  , outfile: CAR.optional CA.string
  , platform: CAR.optional bundlePlatformCodec
  , type: CAR.optional bundleTypeCodec
  , extra_args: CAR.optional (CA.array CA.string)
  }

data BundlePlatform = BundleNode | BundleBrowser

instance Show BundlePlatform where
  show = case _ of
    BundleNode -> "node"
    BundleBrowser -> "browser"

parsePlatform :: String -> Maybe BundlePlatform
parsePlatform = case _ of
  "node" -> Just BundleNode
  "browser" -> Just BundleBrowser
  _ -> Nothing

bundlePlatformCodec :: JsonCodec BundlePlatform
bundlePlatformCodec = CA.Sum.enumSum show (parsePlatform)

-- | This is the equivalent of "WithMain" in the old Spago.
-- App bundles with a main fn, while Module does not include a main.
data BundleType = BundleApp | BundleModule

instance Show BundleType where
  show = case _ of
    BundleApp -> "app"
    BundleModule -> "module"

parseBundleType :: String -> Maybe BundleType
parseBundleType = case _ of
  "app" -> Just BundleApp
  "module" -> Just BundleModule
  _ -> Nothing

bundleTypeCodec :: JsonCodec BundleType
bundleTypeCodec = CA.Sum.enumSum show (parseBundleType)

newtype Dependencies = Dependencies (Map PackageName (Maybe Range))

derive instance Eq Dependencies
derive instance Newtype Dependencies _

instance Semigroup Dependencies where
  append (Dependencies d1) (Dependencies d2) = Dependencies $ Map.unionWith
    ( case _, _ of
        Nothing, Nothing -> Nothing
        Just r, Nothing -> Just r
        Nothing, Just r -> Just r
        Just r1, Just r2 -> Range.intersect r1 r2
    )
    d1
    d2

instance Monoid Dependencies where
  mempty = Dependencies (Map.empty)

dependenciesCodec :: JsonCodec Dependencies
dependenciesCodec = Profunctor.dimap to from $ CA.array dependencyCodec
  where
  packageSingletonCodec = Internal.Codec.packageMap spagoRangeCodec

  to :: Dependencies -> Array (Either PackageName (Map PackageName Range))
  to (Dependencies deps) =
    map
      ( \(Tuple name maybeRange) -> case maybeRange of
          Nothing -> Left name
          Just r -> Right (Map.singleton name r)
      )
      $ Map.toUnfoldable deps :: Array _

  from :: Array (Either PackageName (Map PackageName Range)) -> Dependencies
  from = Dependencies <<< Map.fromFoldable <<< map
    ( case _ of
        Left name -> Tuple name Nothing
        Right m -> rmap Just $ unsafeFromJust (List.head (Map.toUnfoldable m))
    )

  dependencyCodec :: JsonCodec (Either PackageName (Map PackageName Range))
  dependencyCodec = CA.codec' decode encode
    where
    encode = case _ of
      Left name -> CA.encode PackageName.codec name
      Right singletonMap -> CA.encode packageSingletonCodec singletonMap

    decode json =
      map Left (CA.decode PackageName.codec json)
        <|> map Right (CA.decode packageSingletonCodec json)

widestRange :: Range
widestRange = Either.fromRight' (\_ -> unsafeCrashWith "Fake range failed")
  $ Range.parse ">=0.0.0 <2147483647.0.0"

spagoRangeCodec :: JsonCodec Range
spagoRangeCodec = CA.prismaticCodec "SpagoRange" rangeParse printSpagoRange CA.string
  where
  rangeParse str =
    if str == "*" then Just widestRange
    else hush $ Range.parse str

printSpagoRange :: Range -> String
printSpagoRange range =
  if range == widestRange then "*"
  else Range.print range

type WorkspaceConfig =
  { package_set :: Maybe SetAddress
  , extra_packages :: Maybe (Map PackageName ExtraPackage)
  , backend :: Maybe BackendConfig
  , build_opts :: Maybe WorkspaceBuildOptionsInput
  , lock :: Maybe Boolean
  }

workspaceConfigCodec :: JsonCodec WorkspaceConfig
workspaceConfigCodec = CAR.object "WorkspaceConfig"
  { package_set: CAR.optional setAddressCodec
  , extra_packages: CAR.optional (Internal.Codec.packageMap extraPackageCodec)
  , backend: CAR.optional backendConfigCodec
  , build_opts: CAR.optional buildOptionsCodec
  , lock: CAR.optional CA.boolean
  }

type WorkspaceBuildOptionsInput =
  { output :: Maybe FilePath
  , censor_library_warnings :: Maybe CensorBuildWarnings
  , stat_verbosity :: Maybe StatVerbosity
  }

buildOptionsCodec :: JsonCodec WorkspaceBuildOptionsInput
buildOptionsCodec = CAR.object "WorkspaceBuildOptionsInput"
  { output: CAR.optional CA.string
  , censor_library_warnings: CAR.optional censorBuildWarningsCodec
  , stat_verbosity: CAR.optional statVerbosityCodec
  }

data CensorBuildWarnings
  = CensorAllWarnings
  | CensorSpecificWarnings (NonEmptyArray WarningCensorTest)

derive instance Eq CensorBuildWarnings

instance Show CensorBuildWarnings where
  show = case _ of
    CensorAllWarnings -> "CensorAllWarnings"
    CensorSpecificWarnings censorTests -> "(CensorSpecificWarnings " <> show censorTests <> ")"

censorBuildWarningsCodec :: JsonCodec CensorBuildWarnings
censorBuildWarningsCodec = CA.codec' parse print
  where
  print = case _ of
    CensorAllWarnings -> CA.encode CA.string "all"
    CensorSpecificWarnings censorTests -> CA.encode (CA.array warningCensorTestCodec) $ NonEmptyArray.toArray censorTests

  parse j = decodeNoneOrAll <|> decodeSpecific
    where
    decodeNoneOrAll = CA.decode CA.string j >>= case _ of
      "all" -> Right CensorAllWarnings
      _ -> Left $ CA.UnexpectedValue j

    decodeSpecific = CensorSpecificWarnings <$> do
      arr <- CA.decode (CA.array warningCensorTestCodec) j
      Either.note (CA.UnexpectedValue j) $ NonEmptyArray.fromArray arr

data WarningCensorTest
  = ByCode String
  | ByMessagePrefix String

derive instance Eq WarningCensorTest
instance Show WarningCensorTest where
  show = case _ of
    ByCode str -> "(ByCode" <> str <> ")"
    ByMessagePrefix str -> "(ByMessagePrefix" <> str <> ")"

warningCensorTestCodec :: JsonCodec WarningCensorTest
warningCensorTestCodec = CA.codec' parse print
  where
  print = case _ of
    ByCode str -> CA.encode CA.string str
    ByMessagePrefix str -> CA.encode byMessagePrefixCodec { by_prefix: str }

  parse j = byCode <|> byPrefix
    where
    byCode = ByCode <$> CA.decode CA.string j
    byPrefix = (ByMessagePrefix <<< _.by_prefix) <$> CA.decode byMessagePrefixCodec j

  byMessagePrefixCodec = CAR.object "ByMessagePrefix" { by_prefix: CA.string }

data StatVerbosity
  = NoStats
  | CompactStats
  | VerboseStats

instance Show StatVerbosity where
  show = case _ of
    NoStats -> "NoStats"
    CompactStats -> "CompactStats"
    VerboseStats -> "VerboseStats"

statVerbosityCodec :: JsonCodec StatVerbosity
statVerbosityCodec = CA.Sum.enumSum print parse
  where
  print = case _ of
    NoStats -> "no-stats"
    CompactStats -> "compact-stats"
    VerboseStats -> "verbose-stats"
  parse = case _ of
    "no-stats" -> Just NoStats
    "compact-stats" -> Just CompactStats
    "verbose-stats" -> Just VerboseStats
    _ -> Nothing

data SetAddress
  = SetFromRegistry { registry :: Version }
  | SetFromUrl { url :: String, hash :: Maybe Sha256 }
  | SetFromPath { path :: FilePath }

derive instance Eq SetAddress

setAddressCodec :: JsonCodec SetAddress
setAddressCodec = CA.codec' decode encode
  where
  setFromRegistryCodec = CAR.object "SetFromRegistry" { registry: Version.codec }
  setFromUrlCodec = CAR.object "SetFromUrl" { url: CA.string, hash: CAR.optional Sha256.codec }
  setFromPathCodec = CAR.object "SetFromPath" { path: CA.string }

  encode (SetFromRegistry r) = CA.encode setFromRegistryCodec r
  encode (SetFromUrl u) = CA.encode setFromUrlCodec u
  encode (SetFromPath p) = CA.encode setFromPathCodec p

  decode json = map SetFromRegistry (CA.decode setFromRegistryCodec json)
    <|> map SetFromUrl (CA.decode setFromUrlCodec json)
    <|> map SetFromPath (CA.decode setFromPathCodec json)

data ExtraPackage
  = ExtraLocalPackage LocalPackage
  | ExtraRemotePackage RemotePackage

derive instance Eq ExtraPackage

extraPackageCodec :: JsonCodec ExtraPackage
extraPackageCodec = CA.codec' decode encode
  where
  encode (ExtraLocalPackage lp) = CA.encode localPackageCodec lp
  encode (ExtraRemotePackage rp) = CA.encode remotePackageCodec rp

  decode json = map ExtraLocalPackage (CA.decode localPackageCodec json)
    <|> map ExtraRemotePackage (CA.decode remotePackageCodec json)

type LocalPackage = { path :: FilePath }

localPackageCodec :: JsonCodec LocalPackage
localPackageCodec = CAR.object "LocalPackage" { path: CA.string }

data RemotePackage
  = RemoteGitPackage GitPackage
  | RemoteRegistryVersion Version
  | RemoteLegacyPackage LegacyPackageSetEntry

derive instance Eq RemotePackage

remotePackageCodec :: JsonCodec RemotePackage
remotePackageCodec = CA.codec' decode encode
  where
  encode (RemoteRegistryVersion v) = CA.encode Version.codec v
  encode (RemoteGitPackage p) = CA.encode gitPackageCodec p
  encode (RemoteLegacyPackage p) = CA.encode legacyPackageSetEntryCodec p

  decode json = map RemoteRegistryVersion (CA.decode Version.codec json)
    <|> map RemoteGitPackage (CA.decode gitPackageCodec json)
    <|> map RemoteLegacyPackage (CA.decode legacyPackageSetEntryCodec json)

type GitPackage =
  { git :: String
  , ref :: String
  , subdir :: Maybe FilePath
  , dependencies :: Maybe Dependencies
  }

gitPackageCodec :: JsonCodec GitPackage
gitPackageCodec = CAR.object "GitPackage"
  { git: CA.string
  , ref: CA.string
  , subdir: CAR.optional CA.string
  , dependencies: CAR.optional dependenciesCodec
  }

-- | The format of a legacy packages.json package set entry for an individual
-- | package.
type LegacyPackageSetEntry =
  { dependencies :: Array PackageName
  , repo :: String
  , version :: String
  }

legacyPackageSetEntryCodec :: JsonCodec LegacyPackageSetEntry
legacyPackageSetEntryCodec = CAR.object "LegacyPackageSetEntry"
  { dependencies: CA.array PackageName.codec
  , repo: CA.string
  , version: CA.string
  }

readConfig :: forall a. FilePath -> Spago (LogEnv a) (Either String { doc :: YamlDoc Config, yaml :: Config })
readConfig path = do
  logDebug $ "Reading config from " <> path
  FS.exists path >>= case _ of
    false -> pure (Left $ "Did not find " <> path <> " file.")
    true -> liftAff $ FS.readYamlDocFile configCodec path
