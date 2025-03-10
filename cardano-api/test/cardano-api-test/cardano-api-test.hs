module Main where

import           Cardano.Crypto.Libsodium (sodiumInit)

import           System.IO (BufferMode (LineBuffering), hSetBuffering, hSetEncoding, stdout, utf8)

import qualified Test.Cardano.Api.Crypto
import qualified Test.Cardano.Api.Eras
import qualified Test.Cardano.Api.IO
import qualified Test.Cardano.Api.Json
import qualified Test.Cardano.Api.KeysByron
import qualified Test.Cardano.Api.Ledger
import qualified Test.Cardano.Api.Metadata
import qualified Test.Cardano.Api.Typed.Address
import qualified Test.Cardano.Api.Typed.Bech32
import qualified Test.Cardano.Api.Typed.CBOR
import qualified Test.Cardano.Api.Typed.Envelope
import qualified Test.Cardano.Api.Typed.JSON
import qualified Test.Cardano.Api.Typed.Ord
import qualified Test.Cardano.Api.Typed.RawBytes
import qualified Test.Cardano.Api.Typed.TxBody
import qualified Test.Cardano.Api.Typed.Value

import           Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = do
  -- TODO: Remove sodiumInit: https://github.com/input-output-hk/cardano-base/issues/175
  sodiumInit
  hSetBuffering stdout LineBuffering
  hSetEncoding stdout utf8
  defaultMain tests

tests :: TestTree
tests =
  testGroup "Cardano.Api"
    [ Test.Cardano.Api.Crypto.tests
    , Test.Cardano.Api.Eras.tests
    , Test.Cardano.Api.IO.tests
    , Test.Cardano.Api.Json.tests
    , Test.Cardano.Api.KeysByron.tests
    , Test.Cardano.Api.Ledger.tests
    , Test.Cardano.Api.Metadata.tests
    , Test.Cardano.Api.Typed.Address.tests
    , Test.Cardano.Api.Typed.Bech32.tests
    , Test.Cardano.Api.Typed.CBOR.tests
    , Test.Cardano.Api.Typed.Envelope.tests
    , Test.Cardano.Api.Typed.JSON.tests
    , Test.Cardano.Api.Typed.Ord.tests
    , Test.Cardano.Api.Typed.RawBytes.tests
    , Test.Cardano.Api.Typed.TxBody.tests
    , Test.Cardano.Api.Typed.Value.tests
    ]
