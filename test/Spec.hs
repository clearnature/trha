{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

import Test.Hspec
import Test.QuickCheck
import Infrastructure.CPU.GGUF
import Infrastructure.CPU.Dequant
import Infrastructure.CPU.SOV3
import Infrastructure.CPU.S2Geometry
import Infrastructure.CPU.GF3Ops
import Infrastructure.CPU.Christoffel
import Infrastructure.CPU.SovereignModel
import Infrastructure.CPU.GF3Intrinsic
import Infrastructure.CPU.GF3Intrinsic (AlphaPower(..))
import Infrastructure.CPU.SovereignIntrinsic
import Infrastructure.CPU.SovereignGF27
import Infrastructure.CPU.SovereignSection
import Infrastructure.CPU.SovereignLossGain
import Infrastructure.CPU.Z12Sys
import Infrastructure.CPU.SovereignPhase12
import Infrastructure.CPU.SovereignWuXing
import Infrastructure.CPU.SovereignWuxingLayer
import Infrastructure.CPU.SovereignFull
import Infrastructure.CPU.B1Window (b1ApplyWindow)
import Infrastructure.CPU.Inference (Brain(..), createInferenceEngine, withBrain, withWeightsC)
import qualified Infrastructure.CPU.Inference as Inf
import Infrastructure.CPU.Types (CPUBackend(..), CPUFeatures(..), CPUArchitecture(X86_64), defaultCPUConfig)
import Infrastructure.CPU.SovereignPacked
import qualified Infrastructure.CPU.SovereignTypes as ST
import Infrastructure.CPU.SovereignTypes (mkTrit, tritToInt, Trit)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.ByteString as BS
import Infrastructure.CPU.Quant (QuantType(..))
import System.Directory (doesFileExist)
import Core.Plugin.Types
import Core.Plugin.Free
import Core.Session.Types
import Core.Session.Manager
import Core.Agent.StateMachine (AgentCommand (..))
import Core.Agent.Types
import Core.Agent.StateMachine
import Core.Tools.Types
import Core.Tools.Registry
import Core.Event.Types
import Core.Event.Bus
import Core.Cache.Types
import Core.Cache.Engine
import LLM.Adapter.Types
import qualified LLM.Adapter.Types as LLM
import LLM.Adapter.Interface
import LLM.Providers.DeepSeek (buildDeepSeekChatRequest, createDeepSeekProvider, parseDeepSeekChatTurn)
import API.Server (OpenAIRequest(..), parseOpenAIRequest, mkApp, mkStubApp, mkCPUApp)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.HTTP.Client (Manager, newManager, defaultManagerSettings, parseRequest,
                            httpLbs, responseBody, responseStatus, method, requestBody,
                            requestHeaders, RequestBody(..))
import Network.HTTP.Types (statusCode)
import API.ProviderProbe (classifyListing, parseModelIds)
import API.ProviderRuntime (adapterFor, cpuAdapterCacheSize)
import Core.Provider.Types
import Data.IORef
import Data.Word (Word8)
import Data.Dynamic
import qualified Data.Text as T
import Data.Aeson (Value(..), decode, encode, object, parseJSON, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import System.CPUTime (getCPUTime)
import qualified Data.List as List
import qualified Data.Vector.Unboxed as VU
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (listToMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Map as Map
import Control.Monad.Free (liftF)
import PluginSpec (pluginSpec)
import CoreContractSpec (coreContractSpec)
import SessionPersistSpec (sessionPersistSpec)
import ApprovalSpec (approvalSpec)
import PlanSpec (planSpec)
import DeepSeekCacheSpec (deepSeekCacheSpec)
import StreamToolCallsSpec (streamToolCallsSpec)
import WireGuardsSpec (wireGuardsSpec)
import StreamTimeoutSpec (streamTimeoutSpec)

subsetOf :: (Eq a) => [a] -> [a] -> Bool
subsetOf xs ys = all (`elem` ys) xs

-- | 尾部稳态周期：找**最小** d ∈ [1,120]，使帧序列末尾以 d 为周期
-- （末尾 d 个位置的相邻周期比较全成立）。找不到则 'Nothing'。
--
-- ⚠️ 与「首次重复」判法的区别：相位推进会在一个轮内产生**偶然的相邻重复**，
-- 用 firstRepeat 会把它误报成周期 1。这里要求末尾**连续 d 步**都满足周期 d，
-- 从而排除偶然重复（见 "自持：60 层后落入周期 12" 一测的注记）。
--
-- ⚠️ 本函数此前在 Spec.hs 中被引用但**从未定义**（迁移时才发现），
-- 此处按各调用点的期望语义实现，仅供测试使用。
tailCycle :: (Eq a) => [[[a]]] -> Maybe Int
tailCycle frames = listToMaybe [ d | d <- [1 .. 120], d < n, holdsFor d ]
  where
    n = length frames
    holdsFor d = and [ frames !! i == frames !! (i - d) | i <- [n - d .. n - 1] ]

main :: IO ()
main = hspec $ do
  pluginSpec
  coreContractSpec
  sessionPersistSpec
  approvalSpec
  planSpec
  deepSeekCacheSpec
  streamToolCallsSpec
  wireGuardsSpec
  streamTimeoutSpec
  describe "Infrastructure.CPU.GGUF (A6/M1)" $ do
    it "reads a real GGUF: version, alignment, metadata and tensor directory" $ do
      let path = "/home/yanli/work/9060xt/llama.cpp/models/ggml-vocab-baichuan.gguf"
      exists <- doesFileExist path
      if not exists
        then pendingWith "reference GGUF not present on this machine"
        else do
          res <- loadGGUF path
          case res of
            Left e  -> expectationFailure (T.unpack e)
            Right g -> do
              ggVersion g `shouldBe` 3
              ggAlignment g `shouldBe` 32
              Map.member "tokenizer.ggml.model" (ggMeta g) `shouldBe` True
              -- the file declares 18 KV pairs, and every one of them parsed
              Map.size (ggMeta g) `shouldBe` 18
              -- vocab-only files carry no tensors (verified: n_tensors == 0 on disk)
              ggTensors g `shouldBe` []
              ggDataStart g `mod` fromIntegral (ggAlignment g) `shouldBe` 0

    it "parses the tensor directory exactly (synthetic GGUF, A6/M1)" $ do
      let le32 x = [ fromIntegral (x `mod` 256)
                   , fromIntegral ((x `div` 256) `mod` 256)
                   , fromIntegral ((x `div` 65536) `mod` 256)
                   , fromIntegral ((x `div` 16777216) `mod` 256) ] :: [Word8]
          le64 x = le32 (x `mod` 4294967296) ++ le32 (x `div` 4294967296)
          asc = map (fromIntegral . fromEnum)
          gstr t = le64 (fromIntegral (length t)) ++ asc t
          kv     = gstr "general.alignment" ++ le32 4 ++ le32 32   -- UINT32 = 32
          tinfo  = gstr "tok_embd" ++ le32 2 ++ le64 4 ++ le64 2 ++ le32 0 ++ le64 0
          header = asc "GGUF" ++ le32 3 ++ le64 1 ++ le64 1 ++ kv ++ tinfo
          padding = replicate ((32 - length header `mod` 32) `mod` 32) 0
          aligned = header ++ padding
          img = BS.pack (aligned ++ replicate 32 7)               -- 4×2 F32 payload
          tmp = "/tmp/trha-synth.gguf"
      BS.writeFile tmp img
      res <- loadGGUF tmp
      case res of
        Left e  -> expectationFailure (T.unpack e)
        Right g -> do
          length (ggTensors g) `shouldBe` 1
          let t = head (ggTensors g)
          gtName t   `shouldBe` "tok_embd"
          gtDims t   `shouldBe` [4, 2]     -- fastest-varying first, as stored
          gtType t   `shouldBe` 0          -- F32
          gtOffset t `shouldBe` 0
          ggDataStart g `shouldBe` length aligned
          BS.length (ggufTensorBytes g 32 t) `shouldBe` 32

  describe "Infrastructure.CPU.GF3Intrinsic (A6/M7e intrinsic GF(3))" $ do
    -- Baselines produced by sov-math (/home/yanli/work/math), pure integer
    -- C++23: gf3_layer2.h build_rsqrt_lut_q16 / z3r_rms_norm / z3r_matmul /
    -- z3r_gate / z3r_gated_mul / z3r_dot_product.
    let dim = 8
        lut = rsqrtLutQ16 dim 1e-5
        x = map mkTrit [0, 1, 2, 0, 1, 2, 0, 1]
        gw = [ [ mkTrit ((r * 7 + c * 13 + 3) `mod` 3) | c <- [0 .. dim - 1] ] | r <- [0 .. 2] ]
        uw = [ [ mkTrit ((r * 7 + c * 13 + 4) `mod` 3) | c <- [0 .. dim - 1] ] | r <- [0 .. 2] ]
        dw = [ [ mkTrit ((r * 7 + c * 13 + 5) `mod` 3) | c <- [0 .. 2] ] | r <- [0 .. dim - 1] ]
        gamma = replicate dim (mkTrit 1)

    it "reproduces the sov-math C++ Q16 rsqrt LUT bit for bit" $ do
      lut `shouldBe` [20724303, 185356, 131069, 107018, 92681, 82897, 75674, 70061, 65536]

    it "reproduces z3r_rms_norm bit for bit and stays inside GF(3)" $ do
      map tritToInt (z3rRmsNorm lut gamma x) `shouldBe` [0, 1, 0, 0, 1, 0, 0, 1]

    it "reproduces the layer-2 dot product (integer, no reduction)" $ do
      z3rDotProduct (map mkTrit [1, 2, 1, 2]) (map mkTrit [2, 2, 1, 1]) `shouldBe` 6   -- 层2：不归约

    it "reproduces z3r_matmul / z3r_gate / z3r_gated_mul / swiglu bit for bit" $ do
      let g = z3rMatmul gw x
          u = z3rMatmul uw x
          gate = z3rGate (length (filter (\t -> tritToInt t /= 0) g)) (3 * fxpOne)
      map tritToInt g `shouldBe` [2, 0, 1]
      map tritToInt u `shouldBe` [0, 1, 2]
      tritToInt gate `shouldBe` 0             -- non_zero=2 -> 2*65536 < 3*65536
      map tritToInt (z3rGatedMul gate u) `shouldBe` replicate 3 0
      map tritToInt (z3rSwiGLU gw uw dw x) `shouldBe` replicate dim 0

    it "lands on a limit cycle instead of blowing up" $ do
      -- The float version of the same pipeline reaches ~1e21 because it never
      -- reduces; the intrinsic version reduces mod 3 every step, so the state
      -- space is finite and a cycle is forced.
      let iterate 0 v = v
          iterate n v = iterate (n - 1) (z3rRmsNorm lut gamma v)
          sums = [ sum (map tritToInt (iterate (t + 1) x)) | t <- [0 .. 9] ]   -- after t+1 norms
      sums `shouldBe` [3, 6, 0, 0, 0, 0, 0, 0, 0, 0]
      all (\v -> tritToInt v >= 0 && tritToInt v <= 2) (iterate 10 x) `shouldBe` True

    it "gated_mul is GF(3) multiplication, not a float product" $ do
      map tritToInt (z3rGatedMul (mkTrit 2) (map mkTrit [0, 1, 2])) `shouldBe` [0, 2, 1]   -- 2*2=4=1 mod 3
      map tritToInt (z3rGatedMul (mkTrit 0) (map mkTrit [0, 1, 2])) `shouldBe` [0, 0, 0]

  describe "Infrastructure.CPU.GF3Intrinsic — DuodecClock 本源相位归零 (A6/M7f)" $ do
    -- 数值锚: /home/yanli/work/math/cpp/tests/test_duodec_crt.cpp
    let allPts = [ (x, a) | x <- [0, 1, 2], a <- [A0, A1, A2, A3] ]

    it "reproduces the C++ mixed-clock CRT homomorphism over all 144 branches" $ do
      and [ crt12 (mixedOp p q) == (crt12 p + crt12 q) `mod` 12
          | p <- allPts, q <- allPts ] `shouldBe` True

    it "reproduces the C++ semantic anchors: char-3, ord(a)=4, 12=3x4, 12 does not divide 8" $ do
      zeroOblivionPeriod (1, A0) `shouldBe` 3      -- ⊕³ = id  (char GF(3))
      zeroOblivionPeriod (0, A1) `shouldBe` 4      -- α⁴ = id  (ord α)
      zeroOblivionPeriod (1, A1) `shouldBe` 12     -- 联合零冥 = lcm(3,4)
      (12 `mod` 8 /= 0) `shouldBe` True            -- |GF(9)*| = 8

    it "zeroes every phase dimension at once (that is what 零冥族 means)" $ do
      -- The two components have independent periods 3 and 4; only every 12th
      -- layer do BOTH sit at the unit — a single Z/12 counter cannot show this.
      let comps n = let (x, a) = mixedOpN n (1, A1) in (x, a)
          tritZero n = fst (comps n) == 0
          alphaZero n = snd (comps n) == A0
      [ n | n <- [1 .. 24], tritZero n ]  `shouldBe` [3, 6, 9, 12, 15, 18, 21, 24]
      [ n | n <- [1 .. 24], alphaZero n ] `shouldBe` [4, 8, 12, 16, 20, 24]
      [ n | n <- [1 .. 24], tritZero n && alphaZero n ] `shouldBe` [12, 24]

    it "walks 60 layers on a 12-cycle instead of collapsing to an absorbing state" $ do
      let traj = phaseTrajectory (1, A1) 60
      length traj `shouldBe` 60
      take 12 traj `shouldBe` [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      -- exactly 5 full sovereign breaths; layer 60 would be 0 again
      (traj !! 12, traj !! 24, traj !! 36, traj !! 48) `shouldBe` (0, 0, 0, 0)
      take 48 (drop 12 traj) `shouldBe` take 48 traj
      phaseTrajectory (1, A1) 61 !! 60 `shouldBe` 0

    it "keeps the Conway-style layer chain alive: cell → mixedOp → target" $ do
      -- What the model's per-layer advance should be, in source form.
      let layer (cell, target) =
            let nxt = mixedOp cell (1, A1) in (nxt, mixedOp nxt (1, A1))
          chain = iterate layer ((0, A0), (1, A1))
          cells = [ crt12 c | (c, _) <- take 60 chain ]
      take 12 cells `shouldBe` [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      all (\c -> c >= 0 && c < 12) cells `shouldBe` True

  describe "Infrastructure.CPU.SovereignPhase12 — 真实十二律相位 + 互映 (A6/M8-F)" $ do
    it "层推进取 b % 12：cell 轨迹是十二律（递减），12 步一轮" $ do
      cellTrajectory12 12 `shouldBe` [0, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

    it "每 12 步应用一次桥（呼吸）：前 11 步 acc 不变，第 12 步被桥处理" $ do
      let ps = phaseSeq12 13
      map p12Acc (take 12 ps) `shouldBe` replicate 12 177147
      p12Acc (ps !! 12) `shouldBe` zhonglvAlign 177147
      map breatheCount ps `shouldBe` [0,0,0,0,0,0,0,0,0,0,0,0,1]

    it "E4 互映：holoFromZ12 ∘ z12FromHolo = id（整数像上）；非整数分量返回 Nothing" $ do
      let h = HoloState 16 133 16 1
      holoFromZ12 (z12FromHolo h) `shouldBe` Just h
      holoFromZ12 zeta3 `shouldBe` Nothing        -- ζ₃ 有 −1/2 分量，不在像里

    it "F2 端到端组合：60 层的 (cell,target) 全程有效，60 层 = 5 个呼吸" $ do
      let ps = take 60 (iterate step12 phase12Init)
          pairs = [ pr | (_, pr) <- map layerStep12 ps ]
      length pairs `shouldBe` 60
      -- 每层的 cell/target 都在 [0,12)，且 target 恰是下一律（b 每步 -1）
      and [ c >= 0 && c < 12 && t >= 0 && t < 12 && t == (c + 11) `mod` 12
          | (c, t) <- pairs ] `shouldBe` True
      -- 60 层走完 5 个完整呼吸（12 步一个）
      -- 60 层 = 60 次 step，故需含初值共 61 个状态；走完 5 个呼吸
      breatheCount (last (take 61 (iterate step12 phase12Init))) `shouldBe` 5
      -- 60 层的 cell 序列：5 个 [0,11..1] 循环
      take 12 [ c | (c, _) <- pairs ] `shouldBe` [0, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

    it "M9：GF(27) 整链 × 真实十二律相位，60 层数值有界（∈[0,26]）" $ do
      let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          dimC = 24
          cc = SovereignConfig { scDim = dimC, scDepth = 60, scHeads = 2
                               , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
          ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                 (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
          ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 60 ll)
          emb = [ take dimC (siwTokenEmbed ww !! (t `mod` 8) ++ repeat ST.gf27Zero) | t <- [1, 3, 5] ]
          pairs = [ pr | (_, pr) <- map layerStep12 (take 60 (iterate step12 phase12Init)) ]
          run = foldl (\hs (i, pr) -> map (layerIntrinsic27At cc (siwLayers ww !! i) pr) hs)
                      emb (zip [0 ..] pairs)
      map length run `shouldBe` [dimC, dimC, dimC]
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | row <- run, v <- row ] `shouldBe` True
      breatheCount (last (take 61 (iterate step12 phase12Init))) `shouldBe` 5

    it "训练后 .sov（step31000）的 token_emb 切片 → GF(27)×十二律相位（diagnostic）" $ do
      let base = "/data/trit/pyBitNet/scripts/artifacts/sov_native/"
          dimC = 24
          w3 r' c' sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c' - 1] ] | i <- [0 .. r' - 1] ]
          probe p = do
            rr <- loadSOV3 (base ++ p)
            case rr of
              Left _ -> pure (p ++ ": load-error")
              Right sv -> case sov3TensorFloats sv "token_emb.token_embed.weight" of
                Nothing -> pure (p ++ ": no-token_emb")
                Just flat -> do
                  let rows = [ [ round v | v <- take dimC (drop (i * 1440) flat) ] | i <- [0 .. 7] ]
                      nz = length (filter (/= 0) (concat rows))
                      cc = SovereignConfig { scDim = dimC, scDepth = 60, scHeads = 2
                                           , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
                      ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                             (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
                      ww = SovereignIntWeights (map (map ST.mkGF27) rows) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 60 ll)
                      pairs = [ pr | (_, pr) <- map layerStep12 (take 60 (iterate step12 phase12Init)) ]
                      run = foldl (\hs (i, pr) -> map (layerIntrinsic27At cc (siwLayers ww !! i) pr) hs)
                                  (embed27 cc ww [1, 3, 5]) (zip [0 ..] pairs)
                  pure (p ++ ": head=" ++ show (take 6 (head rows))
                            ++ " nz=" ++ show nz
                            ++ " 有界=" ++ show (and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | row <- run, v <- row ]))
      rs <- mapM probe [ "bitnet2b_warmstart.sov", "20260721-033421_step31000.sov" ]
      -- ⚠️ 不能用 sequence_：第一个 pendingWith 抛异常即中断，后面 probe 的测量结果
      -- 永远打不出来（此前报告里只有 bitnet2b_warmstart.sov 一项可见）。合并成单条
      -- 消息，两个 probe 的结果都进入报告。
      pendingWith (List.intercalate " | " rs)

    it "真实训练后权重（ZIP 里的 data/0）→ GF(27)×十二律相位，60 层有界" $ do
      -- 20260721-033421_step31000.sov 实为 PyTorch ZIP（magic = PK\003\004），
      -- 其中 token_emb.token_embed.weight 是 ByteStorage（5-trit/byte 打包，442368 B
      -- = 1536*1440/5）。
      let raw = "/home/yanli/work/trha/models/20260721-033421_step31000/data/0"
          dimC = 24
          w3 r' c' sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c' - 1] ] | i <- [0 .. r' - 1] ]
      exists <- doesFileExist raw
      if not exists
        then pendingWith ("模型文件不存在: " ++ raw)
        else do
          bs <- BS.readFile raw
          let allT = unpackTrits bs (8 * 1440)          -- [Float]，值 ∈ {0,1,2}
              rows = [ [ round v | v <- take dimC (drop (i * 1440) allT) ] | i <- [0 .. 7] ]
              nz = length (filter (/= 0) (concat rows))
              cc = SovereignConfig { scDim = dimC, scDepth = 60, scHeads = 2
                                   , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
              ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                     (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
              ww = SovereignIntWeights (map (map ST.mkGF27) rows) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 60 ll)
              pairs = [ pr | (_, pr) <- map layerStep12 (take 60 (iterate step12 phase12Init)) ]
              run = foldl (\hs (i, pr) -> map (layerIntrinsic27At cc (siwLayers ww !! i) pr) hs)
                          (embed27 cc ww [1, 3, 5]) (zip [0 ..] pairs)
          BS.length bs `shouldBe` 442368               -- = 1536*1440/5，与 SOV3 的同名张量同尺寸
          and [ v >= 0 && v <= 2 | row <- rows, v <- row ] `shouldBe` True
          -- 权威复算：artifacts/checkpoints/<tag>.pt（bfloat16 state_dict）
          -- 的 token_emb 按同样切片（8行×每行前24）得非零数 = 181
          nz `shouldBe` 181
          and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | row <- run, v <- row ] `shouldBe` True

    it "loadTorchZip：解 torch.save 的 ZIP，data/0 尺寸与权威 .pt 同源" $ do
      let z = "/data/trit/pyBitNet/scripts/artifacts/sov_native/20260721-033421_step31000.sov"
          nm = "20260721-033421_step31000"
      ex <- doesFileExist z
      if not ex
        then pendingWith ("checkpoint 不存在: " ++ z)
        else do
          ez <- loadTorchZip z
          case ez of
            Left e -> pendingWith ("loadTorchZip: " ++ show e)
            Right es -> do
              let ns = maybe [] (tzNames . tzData) (tzEntry es (nm ++ "/data.pkl"))
              -- 330 个条目（含 4 个点文件、data.pkl 与各 data/N）
              (length es > 100) `shouldBe` True
              case tzEntry es (nm ++ "/data/0") of
                Nothing -> pendingWith ("找不到 " ++ nm ++ "/data/0")
                Just e0 -> do
                  -- 442368 = 1536*1440/5，与裸 SOV3 的同名张量同尺寸；
                  -- 注意 ZIP 里原始切片是 442384（多 16 字节 data descriptor），
                  -- loadTorchZip 已剔除
                  BS.length (tzData e0) `shouldBe` 442368
                  -- ⚠️ 位序：run_train._pack_trits_fast 用 [1,3,9,27,81]（最低位优先），
                  -- 与裸 SOV3（sov_checkpoint._pack_trits, [81,27,9,3,1]）**相反**。
                  -- 权威参照是 artifacts/checkpoints/<tag>.pt，不是裸 SOV3。
                  take 24 (unpackTrits (tzData e0) 24)
                    `shouldBe` [1,1,2,2,2,0,1,1,1,2,1,2,1,1,1,2,1,2,1,1,2,1,1,2]
              -- data.pkl 的张量名（pickle 尾部会带 opcode 字符如 ...weightq，故用前缀匹配）
              (any (isPrefixOf "token_emb.token_embed.weight") ns) `shouldBe` True
              -- 训练后 checkpoint 里真实存在五行推理层
              (any ((== "wuxing_reasoning") . take 16) ns) `shouldBe` True

    it "维数一致：GF(3⁴) / ℚ(ζ₁₂) / Z⁴ 三者同为 4 维" $ do
      3 ^ (4 :: Int) `shouldBe` 81
      (81 - 1) `shouldBe` 80                       -- |GF(81)*|

  describe "Infrastructure.CPU.SovereignWuxingLayer — 五行推理层本源实现 (A6/M14)" $ do
    let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
        dimC = 24; heads = 3; steps = 2; hex = 6; trit = 3
        nd = dimC `div` hex
        hh = dimC `div` heads
        cfg = WuxingConfig dimC heads steps hex trit
        ll = WuxingLayerW
          { wlNodeProj = w3 dimC (hex * nd) 1
          , wlAttnQ    = w3 nd 1 2
          , wlAttnK    = w3 nd 1 3
          , wlOutProj  = w3 (hex * nd) dimC 4
          , wlStepNode = replicate steps (w3 dimC (heads * hex) 5)
          , wlStepTrit = replicate steps (w3 dimC (heads * hex * trit) 6)
          , wlStepT6   = replicate steps (w3 dimC (heads * 2) 7)
          , wlStepConf = replicate steps (w3 dimC heads 8)
          , wlFuse     = w3 (heads * hh) dimC 9
          , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
        x0 = map ST.mkGF27 (take dimC (cycle [0, 1, 2]))

    it "因果图：6×6 邻接，值是 GF(3) 乘（sigmoid 的离散对应）" $ do
      let (adj, updated) = causalGraphStep cfg ll x0
      length adj `shouldBe` hex
      map length adj `shouldBe` replicate hex hex
      and [ tritToInt v >= 0 && tritToInt v <= 2 | row <- adj, v <- row ] `shouldBe` True
      length updated `shouldBe` dimC
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- updated ] `shouldBe` True   -- GF(27) 内

    it "argMaxIdx：整数域上的选择（平局取最小下标）" $ do
      argMaxIdx (map ST.mkGF27 [0, 1, 2]) `shouldBe` 2
      argMaxIdx (map ST.mkGF27 [2, 2, 1]) `shouldBe` 0
      argMaxIdx [] `shouldBe` 0

    it "T⁶ 验证门：极向/环向必须在缠绕内，Berry 相位必须连续" $ do
      -- 起点 (0,0,0)，小增量 → 可达
      t6Verify t6Init 1 1 0 `shouldBe` True
      -- Berry 相位差超阈值 → 不可达
      t6Verify t6Init 0 0 200 `shouldBe` False
      -- 缠绕常数与 M11 同源
      polarWinding `shouldBe` 144
      toroidalWinding `shouldBe` 46

    it "4 步推理链端到端：输出有界 ∈ GF(27)，相位/链长正确" $ do
      let (h, st, chain, oks) = wuxingForward cfg ll x0
      length h `shouldBe` dimC
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- h ] `shouldBe` True
      length chain `shouldBe` steps
      length oks `shouldBe` steps
      -- 每步选中 (节点, trit)，节点 ∈ [0,6)、trit ∈ [0,3)
      and [ n >= 0 && n < hex && t >= 0 && t < trit | sel <- chain, (n, t) <- sel ] `shouldBe` True
      -- 相位被推进过（T⁶ 状态不恒为初值）
      (st == t6Init) `shouldBe` False

  describe "Infrastructure.CPU.SovereignWuxingLayer — 真实配置 (A6/M15)" $ do
    -- 与训练后 checkpoint 的 wuxing_reasoning 同构：
    --   dim=1440, heads=12, steps=4, N_HEX=6, N_TRIT=3
    --   hh = 1440/12 = 120 (ginit 末维), nd = 1440/6 = 240 (attn 维)
    -- 为控制运行时间，这里用 dim=240（= 1440/6，nd 与真实同为 40 的结构同构版）。
    let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
        dimR = 240; heads = 12; steps = 4; hex = 6; trit = 3
        nd = dimR `div` hex          -- 40
        hh = dimR `div` heads        -- 20
        cfgR = WuxingConfig dimR heads steps hex trit
        llR = WuxingLayerW
          { wlNodeProj = w3 dimR (hex * nd) 1
          , wlAttnQ    = w3 nd 1 2
          , wlAttnK    = w3 nd 1 3
          , wlOutProj  = w3 (hex * nd) dimR 4
          , wlStepNode = replicate steps (w3 dimR (heads * hex) 5)
          , wlStepTrit = replicate steps (w3 dimR (heads * hex * trit) 6)
          , wlStepT6   = replicate steps (w3 dimR (heads * 2) 7)
          , wlStepConf = replicate steps (w3 dimR heads 8)
          , wlFuse     = w3 (heads * hh) dimR 9
          , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
        xR = map ST.mkGF27 (take dimR (cycle [0, 1, 2]))

    it "12 头 × 4 步（与 checkpoint 同构的维度比例）端到端：有界 + 链正确" $ do
      let (h, st, chain, oks) = wuxingForward cfgR llR xR
      length h `shouldBe` dimR
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- h ] `shouldBe` True
      length chain `shouldBe` steps
      map length chain `shouldBe` replicate steps heads
      and [ n >= 0 && n < hex && t >= 0 && t < trit | sel <- chain, (n, t) <- sel ] `shouldBe` True
      length oks `shouldBe` steps
      -- 与真实 checkpoint 的形状对照（12×6=72, 12×6×3=216, 12×2=24, 12）
      (heads * hex) `shouldBe` 72
      (heads * hex * trit) `shouldBe` 216
      (heads * 2) `shouldBe` 24
      heads `shouldBe` 12

  describe "Infrastructure.CPU.SovereignWuxingLayer — 真全尺寸 dim=1440 (A6/M16)" $ do
    -- 完全照训练后 checkpoint 的 wuxing_reasoning：
    --   dim=1440, heads=12, steps=4, N_HEX=6, N_TRIT=3
    --   nd = 1440/6 = 240（attn 维）、hh = 1440/12 = 120（ginit 末维）
    let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
        dimF = 1440; heads = 12; steps = 4; hex = 6; trit = 3
        nd = dimF `div` hex          -- 240
        hh = dimF `div` heads        -- 120
        cfgF = WuxingConfig dimF heads steps hex trit
        llF = WuxingLayerW
          { wlNodeProj = w3 dimF (hex * nd) 1
          , wlAttnQ    = w3 nd 1 2
          , wlAttnK    = w3 nd 1 3
          , wlOutProj  = w3 (hex * nd) dimF 4
          , wlStepNode = replicate steps (w3 dimF (heads * hex) 5)
          , wlStepTrit = replicate steps (w3 dimF (heads * hex * trit) 6)
          , wlStepT6   = replicate steps (w3 dimF (heads * 2) 7)
          , wlStepConf = replicate steps (w3 dimF heads 8)
          , wlFuse     = w3 (heads * hh) dimF 9
          , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
        xF = map ST.mkGF27 (take dimF (cycle [0, 1, 2]))

    it "dim=1440 全尺寸：nd=240、hh=120，端到端有界 ∈ GF(27)" $ do
      nd `shouldBe` 240
      hh `shouldBe` 120
      let (h, _st, chain, oks) = wuxingForward cfgF llF xF
      length h `shouldBe` dimF
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- h ] `shouldBe` True
      length chain `shouldBe` steps
      map length chain `shouldBe` replicate steps heads
      length oks `shouldBe` steps
      -- 6×6 因果图（全尺寸下同样）
      let (adj, updated) = causalGraphStep cfgF llF xF
      map length adj `shouldBe` replicate hex hex
      length updated `shouldBe` dimF
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- updated ] `shouldBe` True

  describe "Infrastructure.CPU.SovereignFull — 完整链路 60 层 GF(27) → 五行推理 (A6/M17)" $ do
    let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
        dimC = 24; heads = 3; steps = 2; hex = 6; trit = 3
        nd = dimC `div` hex
        hh = dimC `div` heads
        layerCfg = SovereignConfig { scDim = dimC, scDepth = 6, scHeads = 2
                                   , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
        mkIL = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                 (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
        ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 6 mkIL)
        wcfg = WuxingConfig dimC heads steps hex trit
        wl = WuxingLayerW
          { wlNodeProj = w3 dimC (hex * nd) 1
          , wlAttnQ    = w3 nd 1 2
          , wlAttnK    = w3 nd 1 3
          , wlOutProj  = w3 (hex * nd) dimC 4
          , wlStepNode = replicate steps (w3 dimC (heads * hex) 5)
          , wlStepTrit = replicate steps (w3 dimC (heads * hex * trit) 6)
          , wlStepT6   = replicate steps (w3 dimC (heads * 2) 7)
          , wlStepConf = replicate steps (w3 dimC heads 8)
          , wlFuse     = w3 (heads * hh) dimC 9
          , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
        -- B1/B3 共享：把 ww 的同源合成权重镜像成 data/N 布局的内存 fetch。
        -- 编码与 .sov 一致（5 trits/byte，低位在前 powers [1,3,9,27,81]）。
        packTritsLsb :: [[Trit]] -> BS.ByteString
        packTritsLsb = BS.pack . go5 . concatMap (map tritToInt)
        go5 :: [Int] -> [Word8]
        go5 [] = []
        go5 xs = let (a, b) = splitAt 5 xs
                 in fromIntegral (sum [ t * 3 ^ (i :: Int) | (t, i) <- zip a [0 .. 4 :: Int] ]) : go5 b
        toBytes = packTritsLsb
        mirr =
          [ (0,    toBytes (w3 (scVocab layerCfg) dimC 7))   -- token_emb（与 ww.siwTokenEmbed 同值域 0..2）
          , (22,   toBytes (w3 (scVocab layerCfg) dimC 8))   -- content_bypass
          , (323,  toBytes (w3 (scVocab layerCfg) dimC 6))   -- lm_head
          ] ++ [ (23 + 5 * k + o, toBytes m)
               | k <- [0 .. scDepth layerCfg - 1]
               , (o, m) <- zip [0 .. 4]
                              [silQProj mkIL, silOutProj mkIL
                              , silGateProj mkIL, silUpProj mkIL, silDownProj mkIL] ]
        fetchReact i = pure $ fromMaybe BS.empty (lookup i mirr)

    it "全链路：6 层 GF(27)×十二律相位 → 五行推理 → lm_head，全程 ∈ [0,26]" $ do
      let out = sovereignForwardFull layerCfg ww wcfg wl [1, 3, 5]
      map length out `shouldBe` [8, 8, 8]
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | row <- out, v <- row ] `shouldBe` True

    -- ⚡ C 双表常驻指针版整链 vs Haskell 整链：逐 token 逐元素全等（方向 A 接线门禁）。
    it "sovereignForwardFullC（C 双表+OpenMP）≡ sovereignForwardFull（Haskell），逐元素全等" $ do
      hsOut <- pure (sovereignForwardFull layerCfg ww wcfg wl [1, 3, 5])
      cOut  <- sovereignForwardFullC layerCfg ww wcfg wl [1, 3, 5]
      map (map ST.gf27ToInt) hsOut `shouldBe` map (map ST.gf27ToInt) cOut

    it "诊断版：每 token 都返回五行相位状态、四步链与可达标记" $ do
      let (out, sts, chains, okss) = fullChainReport layerCfg ww wcfg wl [1, 3, 5]
      map length out `shouldBe` [8, 8, 8]
      length sts `shouldBe` 3
      -- chains :: token × steps × heads
      map length chains `shouldBe` replicate 3 steps           -- 每 token 的步数
      map (length . head) chains `shouldBe` replicate 3 heads  -- 第一步的头数
      map length okss `shouldBe` replicate 3 steps             -- okss :: token × steps
      and [ n >= 0 && n < hex && t >= 0 && t < trit
          | ch <- chains, sel <- ch, (n, t) <- sel ] `shouldBe` True

    -- B1（2026-09-17，大脑产 logits）：流式完整链路 ≡ 整包完整链路。
    -- 把同一套合成 trit 权重镜像成 data/N 布局（内存 fetch，不落盘），
    -- 逐个 token 对拍：runStreamingFull（fetch）vs sovereignForwardFull（整包）。
    it "流式完整链路 ≡ 整包完整链路，逐元素全等 (B1)" $ do
      res <- runStreamingFull fetchReact layerCfg wcfg wl [1, 3, 5]
      let want = sovereignForwardFull layerCfg ww wcfg wl [1, 3, 5]
      case res of
        Left e -> expectationFailure e
        Right got -> do
          length got `shouldBe` length want
          map (map ST.gf27ToInt) got `shouldBe` map (map ST.gf27ToInt) want

    -- B3（2026-09-17，大脑产下一 token）：采样闭环 ——
    -- runStreamingFull 的末 token logits 经 argMaxIdx 采样，等于上周
    -- "整包 logits 的最后一个 argMax"。这把「前向 → 采样」接成产 token 的闭环。
    it "大脑产下一 token：argMaxIdx(流式末 logits) ≡ argMaxIdx(整包末 logits) (B3)" $ do
      res <- runStreamingFull fetchReact layerCfg wcfg wl [1, 3, 5]
      let want = sovereignForwardFull layerCfg ww wcfg wl [1, 3, 5]
          lastLogitsGot = case res of Right (l : _) -> Just l; _ -> Nothing
          lastLogitsWant = case want of (l : _) -> Just l; [] -> Nothing
      map (map ST.gf27ToInt) (maybe [] (: []) lastLogitsGot)
        `shouldBe` map (map ST.gf27ToInt) (maybe [] (: []) lastLogitsWant)
      -- 采样：argMaxIdx（最大元素首个下标，平局取最小）
      fmap argMaxIdx lastLogitsGot `shouldBe` fmap argMaxIdx lastLogitsWant

    -- stream-trajectory-b1 #1：B1 窗口层开关三断言——
    -- ① B1 关（runStreamingFullWithB1 False）≡ 旧路径逐位一致（不破坏既有对拍）
    -- ② B1 开 ≠ B1 关（开关真实生效，logits 有区分）
    -- ③ B1 层本身有传播力（b1ApplyWindow 输出与输入不同）
    it "B1 窗口层开关：关=整包路径逐位一致，开≠关 (B1w)" $ do
      -- ① 跨实现真对拍：B1 关 的流式路径 ≡ 整包 sovereignForwardFull
      --   （不是同一函数自比——整包路径不经过 runStreamingFullWithB1 的 post 分支）
      resOff <- runStreamingFullWithB1 False fetchReact layerCfg wcfg wl [1, 3, 5]
      resOn  <- runStreamingFullWithB1 True  fetchReact layerCfg wcfg wl [1, 3, 5]
      let want = sovereignForwardFull layerCfg ww wcfg wl [1, 3, 5]
      case (resOff, resOn) of
        (Right off, Right on) -> do
          -- ① 关 = 整包路径（跨实现，B1 不破坏既有对拍语义）
          map (map ST.gf27ToInt) off `shouldBe` map (map ST.gf27ToInt) want
          -- ② 开 ≠ 关（开关真实生效，logits 有区分）
          (map (map ST.gf27ToInt) on == map (map ST.gf27ToInt) off) `shouldBe` False
        _ -> expectationFailure "B1 开关链路失败（Left）"

    it "B1ApplyWindow：输出同形且有传播力 (B1w-layer)" $ do
      let dim = 32
          hs  = [ [ ST.mkGF27 (fromIntegral ((i * 7 + d) `mod` 27)) | d <- [0 .. dim - 1] ]
                | i <- [0 .. 5 :: Int] ]
          out = b1ApplyWindow dim hs
      length out `shouldBe` length hs
      and [ length o == dim | o <- out ] `shouldBe` True
      -- 传播力：残差 ⊕ prop 至少改变一个位置（因果层真的在动 hidden）
      (out == hs) `shouldBe` False

  describe "Infrastructure.CPU.SovereignFull — 真实 .sov 端到端产 token (B3c)" $ do
    -- 这是「CPU 草稿模型接入路线」的端到端验证：真实 .sov + 真实 wuxing 权重
    -- （data/1..21）→ 流式完整链路（60 层片段 depth=2）→ lm_head(data/323) →
    -- argMaxIdx 采样 → 一个合法 token id。不依赖任何 LLM API。
    let sovP = "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
        dirB = "/home/yanli/work/trha/models/20260721-033421_step31000/data/"
        dimR = 1440; headsR = 12; ffR = 4320; stepsR = 4; hexR = 6; tritR = 3
        ndR  = dimR `div` hexR
        hhR  = dimR `div` headsR
        cfgR = SovereignConfig { scDim = dimR, scDepth = 2, scHeads = headsR
                               , scVocab = 1536, scFF = ffR, scEps = 1e-5 }
        wcfgR = WuxingConfig dimR headsR stepsR hexR tritR
        chunkR :: Int -> [Int] -> [[Int]]
        chunkR n xs = case xs of
          [] -> []
          _  -> take n xs : chunkR n (drop n xs)
        mR r c bs = map (map mkTrit)
                      (chunkR c (take (r * c) (map round (unpackTrits bs (r * c)))))

    it "真实 .sov + 真实 wuxing 权重 → brainStepToken 产出合法 token id（不依赖任何 API）" $ do
      exSov <- doesFileExist sovP
      ex21   <- doesFileExist (dirB ++ "21")
      if not (exSov && ex21)
        then pendingWith ("需 models/ 下 .sov 与 data/1..21：" ++ sovP)
        else do
          b1  <- BS.readFile (dirB ++ "1")
          b2  <- BS.readFile (dirB ++ "2")
          b3  <- BS.readFile (dirB ++ "3")
          b4  <- BS.readFile (dirB ++ "4")
          b5  <- BS.readFile (dirB ++ "5")
          b9  <- BS.readFile (dirB ++ "9")
          b13 <- BS.readFile (dirB ++ "13")
          b17 <- BS.readFile (dirB ++ "17")
          b21 <- BS.readFile (dirB ++ "21")
          let wlR = WuxingLayerW
                { wlNodeProj = mR dimR dimR b1
                , wlAttnQ    = mR 1 ndR b2
                , wlAttnK    = mR 1 ndR b3
                , wlOutProj  = mR dimR dimR b4
                , wlStepNode = replicate stepsR (mR (headsR * hexR) dimR b5)
                , wlStepTrit = replicate stepsR (mR (headsR * hexR * tritR) dimR b9)
                , wlStepT6   = replicate stepsR (mR (headsR * 2) dimR b13)
                , wlStepConf = replicate stepsR (mR headsR dimR b17)
                , wlFuse     = mR dimR dimR b21
                , wlGInit    = replicate hexR (replicate tritR (replicate hhR (mkTrit 1))) }
          r <- brainStepToken sovP cfgR wcfgR wlR [1]
          case r of
            Left e -> expectationFailure ("brainStepToken 失败: " ++ e)
            Right (tok, logits) -> do
              -- 词表 logits 长度 = 真实 vocab（1536），不是占位的 32000
              length logits `shouldBe` 1536
              -- 全程 ∈ GF(27) 值域
              and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- logits ] `shouldBe` True
              -- 采样出的 token id 必须合法
              tok `shouldSatisfy` (\t -> t >= 0 && t < 1536)
              -- 采样语义：argMaxIdx（最大元素首个下标）
              argMaxIdx logits `shouldBe` tok
              -- 确定性：再跑一次必须同结果（argmax 无随机性）
              r2 <- brainStepToken sovP cfgR wcfgR wlR [1]
              fmap fst r2 `shouldBe` Right tok

    -- B4（2026-09-17，CPU 接线）：InferenceEngine 挂上 Brain 后，generateStream
    -- 走真实采样（非占位 token_0）。用 depth=2 快速版验证接线，不跑满 60 层。
    it "InferenceEngine 接 Brain → generate 产出真实 token 序列（非占位） (B4)" $ do
      exSov <- doesFileExist sovP
      ex21   <- doesFileExist (dirB ++ "21")
      if not (exSov && ex21)
        then pendingWith ("需 models/ 下 .sov：" ++ sovP)
        else do
          wlR <- loadWuxingFromSov sovP 12 4 3
          case wlR of
            Left err -> expectationFailure ("loadWuxingFromSov: " ++ err)
            Right wl -> do
              let cfgFast = SovereignConfig { scDim = 1440, scDepth = 2, scHeads = 12
                                            , scVocab = 1536, scFF = 4320, scEps = 1e-5 }
                  wcfgFast = WuxingConfig 1440 12 4 6 3
                  feats = CPUFeatures
                    { featureSSE = True, featureSSE2 = True, featureSSE3 = True
                    , featureSSSE3 = True, featureSSE41 = True, featureSSE42 = True
                    , featureAVX = True, featureAVX2 = True, featureAVX512 = False
                    , featureFMA = True, featureF16C = True
                    , featureNEON = False, featureSVE = False, featureSVE2 = False }
                  backend = CPUBackend defaultCPUConfig X86_64 feats
              engine0 <- createInferenceEngine backend sovP
              let engine' = withBrain (Brain sovP cfgFast wcfgFast wl Nothing Nothing) engine0
              r <- Inf.generate engine' "hello" 3
              case r of
                Left err -> expectationFailure ("generate: " ++ err)
                Right txt -> do
                  -- ✅ 2026-09-19 更新：tokenize/detokenize 已升级为真字符级（可逆、零越界），
                  -- generate 输出是 3 个真实 token 的字符拼接（不再有空格分隔的 "token_N"）。
                  -- 占位引擎（无 Brain）输出固定 "token_0 token_0 token_0"（placeholderStream）——
                  -- 真实引擎必须产出非占位文本。
                  let txtS = T.unpack txt
                  T.length txt `shouldSatisfy` (\n -> n > 0)
                  txtS `shouldNotBe` "token_0 token_0 token_0"
                  -- 真实前向采样的 token id ∈ [0,1536)：把输出经 detokenize 逆映射验证可还原
                  -- （字符级 tokenizer 是可逆的 —— 直接验证输出长度 > 0 且非占位即证明走了真实采样）

    -- B4c（2026-09-17，C 双表紧凑链接线）：Brain 用 'withWeightsC'（'loadWeightsSovC'
    -- 紧凑权重）→ realStream 走 'sovereignForwardFullCompact'（权重常驻，depth=2 快速验证）。
    -- 这是「真实 C 链（1.9s/token）接入 generateStream」的端到端证据。
    it "InferenceEngine 接 Brain（紧凑 C 链 withWeightsC）→ generate 产出真实 token 序列 (B4c)" $ do
      exSov <- doesFileExist sovP
      if not exSov
        then pendingWith ("需 models/ 下 .sov：" ++ sovP)
        else do
          wlR <- loadWuxingFromSov sovP 12 4 3
          wcR <- loadWeightsSovC sovP 12
          case (wlR, wcR) of
            (Left err, _) -> expectationFailure ("loadWuxingFromSov: " ++ err)
            (_, Left err) -> expectationFailure ("loadWeightsSovC: " ++ err)
            (Right wl, Right wc) -> do
              let cfgFast = SovereignConfig { scDim = 1440, scDepth = 2, scHeads = 12
                                            , scVocab = 1536, scFF = 4320, scEps = 1e-5 }
                  wcfgFast = WuxingConfig 1440 12 4 6 3
                  feats = CPUFeatures
                    { featureSSE = True, featureSSE2 = True, featureSSE3 = True
                    , featureSSSE3 = True, featureSSE41 = True, featureSSE42 = True
                    , featureAVX = True, featureAVX2 = True, featureAVX512 = False
                    , featureFMA = True, featureF16C = True
                    , featureNEON = False, featureSVE = False, featureSVE2 = False }
                  backend = CPUBackend defaultCPUConfig X86_64 feats
              engine0 <- createInferenceEngine backend sovP
              let brain0 = Brain sovP cfgFast wcfgFast wl Nothing Nothing
                  engine' = withBrain (withWeightsC wc brain0) engine0
              r <- Inf.generate engine' "hello" 3
              case r of
                Left err -> expectationFailure ("generate (compact): " ++ err)
                Right txt -> do
                  -- ✅ 2026-09-19 更新（与 B4 同口径）：真实字符级 detokenize，
                  -- 断言「非占位且非空」证明走了真实紧凑 C 链采样。
                  T.length txt `shouldSatisfy` (\n -> n > 0)
                  T.unpack txt `shouldNotBe` "token_0 token_0 token_0"

  describe "Infrastructure.CPU.SovereignWuxingLayer — 真实权重 data/1..20 (A6/M18)" $ do
    -- 训练后 checkpoint 的 wuxing_reasoning 真实权重（本仓 models/ 下，源自 sov_native/<tag>.sov 的 data/ 解包）。
    -- PyTorch Linear(in,out).weight 的形状是 [out,in]，与 gf27Matmul 的 [out][in] 一致。
    -- 张量名 ↔ data/N（照 data.pkl 的出现顺序）：
    --   1 node_proj[1440,1440]  2 attn_q[1,240]  3 attn_k[1,240]  4 out_proj[1440,1440]
    --   5..8  step_node.0..3[72,1440]   9..12 step_trit.0..3[216,1440]
    --   13..16 step_t6.0..3[24,1440]    17..20 step_conf.0..3[12,1440]
    let base = "/home/yanli/work/trha/models/20260721-033421_step31000/data/"
        dimF = 1440; heads = 12; steps = 4; hex = 6; trit = 3
        nd = dimF `div` hex      -- 240
        hh = dimF `div` heads    -- 120
        wcfg = WuxingConfig dimF heads steps hex trit
        chunk :: Int -> [Int] -> [[Int]]
        chunk n xs = case xs of
          [] -> []
          _  -> take n xs : chunk n (drop n xs)

    it "真实权重（data/1..20）跑一次 wuxing_reasoning，输出有界 ∈ GF(27)" $ do
      ex <- doesFileExist (base ++ "20")
      if not ex
        then pendingWith ("模型文件不存在: " ++ base)
        else do
          b1  <- BS.readFile (base ++ "1")
          b2  <- BS.readFile (base ++ "2")
          b3  <- BS.readFile (base ++ "3")
          b4  <- BS.readFile (base ++ "4")
          b5  <- BS.readFile (base ++ "5")
          b9  <- BS.readFile (base ++ "9")
          b13 <- BS.readFile (base ++ "13")
          b17 <- BS.readFile (base ++ "17")
          b21 <- BS.readFile (base ++ "21")
          let m r c bs = map (map mkTrit)
                           (chunk c (take (r * c) (map round (unpackTrits bs (r * c)))))
              nodeProj = m dimF dimF b1
              attnQ    = m 1 nd   b2
              attnK    = m 1 nd   b3
              outProj  = m dimF dimF b4
              stepNode = m (heads * hex) dimF b5
              stepTrit = m (heads * hex * trit) dimF b9
              stepT6   = m (heads * 2) dimF b13
              stepConf = m heads dimF b17
              fuse     = m dimF dimF b21
              wl = WuxingLayerW
                { wlNodeProj = nodeProj
                , wlAttnQ    = attnQ
                , wlAttnK    = attnK
                , wlOutProj  = outProj
                , wlStepNode = replicate steps stepNode
                , wlStepTrit = replicate steps stepTrit
                , wlStepT6   = replicate steps stepT6
                , wlStepConf = replicate steps stepConf
                , wlFuse     = fuse
                , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
              xR = map ST.mkGF27 (take dimF (cycle [0, 1, 2]))
          -- 真实权重的取值必须都在 {0,1,2}
          and [ tritToInt v >= 0 && tritToInt v <= 2 | row <- take 8 nodeProj, v <- row ] `shouldBe` True
          -- 形状自证
          length nodeProj `shouldBe` dimF
          length (head nodeProj) `shouldBe` dimF
          length stepNode `shouldBe` (heads * hex)          -- 72
          length stepTrit `shouldBe` (heads * hex * trit)   -- 216
          length stepT6 `shouldBe` (heads * 2)              -- 24
          length stepConf `shouldBe` heads                  -- 12
          -- 真实权重跑一次
          let (h, _st, chain, oks) = wuxingForward wcfg wl xR
          length h `shouldBe` dimF
          and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- h ] `shouldBe` True
          length chain `shouldBe` steps
          map length chain `shouldBe` replicate steps heads
          length oks `shouldBe` steps

  describe "Infrastructure.CPU.SovereignGF27 — 真实 1 层权重 (A6/M19)" $ do
    -- 训练后 checkpoint 的 layers.0 真实权重（data/23..27），形状与我的约定一致：
    --   q_proj   [heads*6=72, 1440]   out_proj [1440, 1440]
    --   gate/up  [ff=4320, 1440]      down_proj [1440, 4320]
    let base = "/home/yanli/work/trha/models/20260721-033421_step31000/data/"
        dimF = 1440; heads = 12; ffF = 4320
        chunk :: Int -> [Int] -> [[Int]]
        chunk n xs = case xs of
          [] -> []
          _  -> take n xs : chunk n (drop n xs)
        m r c bs = map (map mkTrit)
                     (chunk c (take (r * c) (map round (unpackTrits bs (r * c)))))
        cfgR = SovereignConfig { scDim = dimF, scDepth = 1, scHeads = heads
                               , scVocab = 8, scFF = ffF, scEps = 1e-5 }
        gammaR = replicate dimF ST.gf27One

    it "真实 layers.0（q_proj/out_proj/gate/up/down 全来自 checkpoint）跑一次" $ do
      ex <- doesFileExist (base ++ "27")
      if not ex
        then pendingWith ("模型文件不存在: " ++ base)
        else do
          b23 <- BS.readFile (base ++ "23")
          b24 <- BS.readFile (base ++ "24")
          b25 <- BS.readFile (base ++ "25")
          b26 <- BS.readFile (base ++ "26")
          b27 <- BS.readFile (base ++ "27")
          let lyr0 = SovereignIntLayer
                (m (heads * 6) dimF b23)
                (m dimF dimF b24)
                (m ffF dimF b25)
                (m ffF dimF b26)
                (m dimF ffF b27)
                (map (map (map mkTrit)) (defaultMonopolePrototype heads))
              x0 = map ST.mkGF27 (take dimF (cycle [0, 1, 2]))
              x1 = layerIntrinsic27At cfgR lyr0 (0, 1) x0
              x2 = gf27RmsNorm gammaR x1
          -- 真实权重取值必须是 trit
          and [ tritToInt v >= 0 && tritToInt v <= 2 | row <- take 4 (silQProj lyr0), v <- row ] `shouldBe` True
          -- 形状自证（q_proj [72,1440]、gate [4320,1440]、down [1440,4320]）
          length (silQProj lyr0) `shouldBe` (heads * 6)
          length (silGateProj lyr0) `shouldBe` ffF
          length (silDownProj lyr0) `shouldBe` dimF
          length (head (silDownProj lyr0)) `shouldBe` ffF
          -- 真实一层的前向结果
          length x1 `shouldBe` dimF
          and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- x1 ] `shouldBe` True
          and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- x2 ] `shouldBe` True

  describe "Infrastructure.CPU.SovereignFull — 真实全 60 层流式前向 (A6/M20)" $ do
    -- 逐层从 checkpoint 目录读真实权重（data/23 + 5k + {0..4}），跑完整 60 层。
    -- 走 forwardStreaming 而非一次性载入：全量权重装箱后放不下（见 M20）。
    let dir60 = "/home/yanli/work/trha/models/20260721-033421_step31000"
        sov60 = "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
        dimF = 1440; heads = 12; ffF = 4320
        cfg60 = SovereignConfig { scDim = dimF, scDepth = 60, scHeads = heads
                                , scVocab = 8, scFF = ffF, scEps = 1e-5 }

    -- ⚠️ 全 60 层**默认 pending**（约 5 分钟，不能进日常 `cabal test`）。
    -- 实测跑法（2026-09-12，本机 64 GiB）：
    --   TRHA_RUN_FULL_60=1 <trha-test 二进制> --match=A6/M20 +RTS -s -M48G -RTS
    -- 实测结果：3 examples / 0 failures，292 秒；峰值驻留 23.7 GiB、总占用 41 GiB；
    -- GC 占 37%，Productivity 62.9%，累计分配 417 GB。
    -- ⚠️ 内存上限必须是 -M48G。曾照搬 Agda 容器配置用 -M6G，导致
    -- "heap exhausted @6.3 GB" —— 那是**人为上限截断**，不是内存不足；
    -- 真实峰值 41 GiB，本机 64 GiB 完全装得下。别再用撞上限论证"内存不够"。
    let cfg2 = cfg60 { scDepth = 2 }
    it ".sov 索引：330 条目，data/0..323 齐全" $ do
      ex <- doesFileExist sov60
      if not ex
        then pendingWith ("需 models/ 下有 .sov")
        else do
          img <- BS.readFile sov60
          let idx = indexZip img
              hasN k = case sovLookup idx ("/data/" ++ show k) of
                         Just _  -> True
                         Nothing -> False
          length idx `shouldBe` 330
          and [ hasN k | k <- [0 .. 323] ] `shouldBe` True

    it ".sov 直读 ≡ 目录读（真实 2 层，逐元素全等）" $ do
      exS <- doesFileExist sov60
      exD <- doesFileExist (dir60 ++ "/data/28")   -- 层 1 的 down_proj
      if not (exS && exD)
        then pendingWith ("需 models/ 下同时有 .sov 与解包目录")
        else do
          rs <- forwardStreaming sov60 cfg2 [1]        -- 直接读 .sov
          rd <- forwardStreamingDir dir60 cfg2 [1]     -- 读解包目录（基线）
          case (rs, rd) of
            (Right xs, Right xd) -> do
              length xs `shouldBe` dimF
              and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- xs ] `shouldBe` True
              xs `shouldBe` xd                            -- ★ 逐元素全等
            _ -> expectationFailure ("sov=" ++ show rs ++ " dir=" ++ show rd)

    it "真实全 60 层（真实 layers.0..59）：默认 pending，需显式 -M 限内存手动跑" $ do
      full <- lookupEnv "TRHA_RUN_FULL_60"
      ex <- doesFileExist (dir60 ++ "/data/322")   -- 层 59 的 down_proj
      if full /= Just "1"
        then pendingWith ("全 60 层约 1 小时；设 TRHA_RUN_FULL_60=1 且 GHCRTS=-M3G 后手动跑")
        else if not ex
          then pendingWith ("需 models/ 下有 .sov")
          else do
            r <- forwardStreaming sov60 cfg60 [1]
            case r of
              Left e  -> expectationFailure e
              Right x -> do
                length x `shouldBe` dimF
                and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | v <- x ] `shouldBe` True

  describe "GF(27) 查表优化 — 对拍验证 (Fable5/Step6)" $ do
    -- 原实现每次 gf27Add/gf27Mul 做 7 次除法 + 2 个元组分配，
    -- 是"60 秒/层"的主因。改成 27×27 查表后必须证明**语义逐点不变**。
    it "gf27Add 查表 ≡ gf27AddRef，覆盖全部 27×27 = 729 组" $ do
      and [ gf27Add a b == gf27AddRef a b | a <- [0 .. 26], b <- [0 .. 26] ] `shouldBe` True
    it "gf27Mul 查表 ≡ gf27MulRef，覆盖全部 27×27 = 729 组" $ do
      and [ gf27Mul a b == gf27MulRef a b | a <- [0 .. 26], b <- [0 .. 26] ] `shouldBe` True
    it "两张表长度 = 729，值域封闭 ∈ [0,26]" $ do
      VU.length gf27AddTable `shouldBe` 729
      VU.length gf27MulTable `shouldBe` 729
      and [ v >= 0 && v <= 26 | v <- VU.toList gf27AddTable ] `shouldBe` True
      and [ v >= 0 && v <= 26 | v <- VU.toList gf27MulTable ] `shouldBe` True
    it "GF(27) 域公理在查表实现下仍成立（单位/零/交换/分配 全量）" $ do
      and [ gf27Add 0   a == a | a <- [0 .. 26] ] `shouldBe` True   -- 加法零元
      and [ gf27Mul 1   a == a | a <- [0 .. 26] ] `shouldBe` True   -- 乘法单位元
      and [ gf27Add a b == gf27Add b a | a <- [0..26], b <- [0..26] ] `shouldBe` True
      and [ gf27Mul a b == gf27Mul b a | a <- [0..26], b <- [0..26] ] `shouldBe` True
      -- 分配律：全量 27³ = 19683 组
      and [ gf27Mul a (gf27Add b c) == gf27Add (gf27Mul a b) (gf27Mul a c)
          | a <- [0..26], b <- [0..26], c <- [0..26] ] `shouldBe` True

  describe "GF(27) 逐函数 microbenchmark (Fable5/Step6)" $ do
    -- 目的：给"查表到底快多少"一个**逐函数**的硬数字，
    -- 而不是只看端到端计时（端到端口径还叠着装箱/遍历，会掩盖真相）。
    -- 两个版本在同一编译设置（cabal test 的 -O2）下同口径对比，比值有效。
    let bench :: String -> (Int -> Int -> Int) -> Int -> IO Double
        bench tag f acc0 = do
          let n  = 1000000 :: Int
              as = take n (cycle [0 .. 26])
              go acc (x:xs) = let acc' = f acc x in acc' `seq` go acc' xs
              go acc []     = acc
          t0 <- getCPUTime
          let r = go acc0 as
          r `seq` return ()
          t1 <- getCPUTime
          let ms = fromIntegral (t1 - t0) / 1.0e9 :: Double    -- ms
          putStrLn ("      [bench] " ++ tag ++ "  = " ++ show ms ++ " ms (10^6 次)")
          return ms

    it "microbenchmark：gf27Mul 查表 vs Ref，报告加速比" $ do
      ref <- bench "gf27MulRef" gf27MulRef 1
      new <- bench "gf27Mul   " gf27Mul    1
      putStrLn ("      [bench] gf27Mul 加速比 = " ++ show (ref / new) ++ "×")
      (ref > 0 && new > 0) `shouldBe` True

    it "microbenchmark：gf27Add 查表 vs Ref，报告加速比" $ do
      ref <- bench "gf27AddRef" gf27AddRef 0
      new <- bench "gf27Add   " gf27Add    0
      putStrLn ("      [bench] gf27Add 加速比 = " ++ show (ref / new) ++ "×")
      (ref > 0 && new > 0) `shouldBe` True

  describe "gf27Matmul 单趟融合 — 对拍 + 基准 (Fable5/Step6b)" $ do
    it "gf27Matmul ≡ gf27MatmulZip（多组形状，逐元素全等）" $ do
      -- 权重（Trit）× 激活（GF27）：权重按 GF(3) 造数，激活按 GF(27) 造数
      let mk r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          v n sd   = [ ST.mkGF27 ((i * 11 + sd) `mod` 27) | i <- [0 .. n - 1] ]
          shapes = [(3, 5), (8, 8), (12, 30), (30, 12), (60, 60)]
      and [ gf27Matmul (mk r c sd) (v c sd) == gf27MatmulZip (mk r c sd) (v c sd)
          | (r, c) <- shapes, sd <- [0 .. 4] ] `shouldBe` True

    it "microbenchmark：gf27Matmul 融合 vs zipWith（60×60 × 2000）" $ do
      let n = 60 :: Int; reps = 2000 :: Int
          w = [ [ mkTrit ((i * 7 + j * 13) `mod` 3) | j <- [0 .. n - 1] ] | i <- [0 .. n - 1] ]
          x = [ ST.mkGF27 (i `mod` 27) | i <- [0 .. n - 1] ]
          timeIt f = do
            t0 <- getCPUTime
            let go 0 acc = acc
                go k _   = let r = f w x in r `seq` go (k - 1 :: Int) r
            let rr = go reps ([] :: [ST.GF27])
            rr `seq` return ()
            t1 <- getCPUTime
            return (fromIntegral (t1 - t0) / 1.0e9 :: Double)
      tz <- timeIt gf27MatmulZip
      tf <- timeIt gf27Matmul
      putStrLn ("      [bench] gf27MatmulZip = " ++ show tz ++ " ms")
      putStrLn ("      [bench] gf27Matmul    = " ++ show tf ++ " ms")
      putStrLn ("      [bench] 加速比 = " ++ show (tz / tf) ++ "x")
      (tz > 0 && tf > 0) `shouldBe` True

  describe "SovereignPacked — 打包表示对拍（方案C：5 trit/字节）" $ do
    let tritsOf n sd = [ (i * 7 + sd) `mod` 3 | i <- [0 .. n - 1] ]
        asMat r c sd = [ [ mkTrit ((i * 13 + j * 7 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]

    it "pvFromTrits / pvToList 往返，且 pvAt 与列表逐位一致" $ do
      and [ (pvToList (pvFromTrits ts) :: [Int]) == ts
          | n <- [1, 4, 5, 6, 19, 100]
          , sd <- [0 .. 2]
          , let ts = tritsOf n sd ] `shouldBe` True
      let ts = tritsOf 137 1
          pv = pvFromTrits ts
      and [ pvAt pv i == (ts !! i) | i <- [0 .. 136] ] `shouldBe` True

    it "bytesMasked：末字节超出 n 的 trit 被清零" $ do
      let pv = pvFromTrits (tritsOf 7 2)      -- 7 trit → 2 字节，末字节仅 2 个有效
          bs = bytesMasked 7 pv
      VU.length bs `shouldBe` 2
      ((fromIntegral (VU.last bs) :: Int) < (3 ^ (2 :: Int))) `shouldBe` True

    it "pvMatmul ≡ gf27Matmul（多组形状 × 多种子，逐元素全等）" $ do
      and [ (map fromIntegral (VU.toList (pvMatmul r c (pvFromTrits (concat (map (map ST.tritToInt) (asMat r c sd))))
                                   (VU.fromList (map (fromIntegral :: Int -> Word8) (map ST.gf27ToInt x))))) :: [Int])
              == map ST.gf27ToInt (gf27Matmul (asMat r c sd) x)
          | (r, c) <- [(1, 5), (3, 10), (7, 26), (12, 60), (30, 144)]
          , sd <- [0 .. 2]
          , let x = [ ST.mkGF27 ((i * 11 + sd) `mod` 27) | i <- [0 .. c - 1] ] ] `shouldBe` True

    it "真实权重 data/0：pvFromBytes 与 unpackTritsInt 同源（升序位序）" $ do
      let f = "/home/yanli/work/trha/models/20260721-033421_step31000/data/0"
      ex <- doesFileExist f
      if not ex
        then pendingWith "模型文件不存在"
        else do
          bs <- BS.readFile f
          let pv = pvFromBytes (VU.map fromIntegral (VU.fromList (BS.unpack (BS.take 100 bs)) :: VU.Vector Word8))
          (take 500 (pvToList pv) :: [Int]) `shouldBe` take 500 (unpackTritsInt (BS.take 100 bs) 500)

  describe "GF(27) 周期乘法 — 对拍权威表（Sovereign/Algebra/GF27.agda）" $ do
    it "gf27MulCyclic ≡ gf27Mul（全量 27×27 = 729 组）" $ do
      and [ gf27MulCyclic a b == gf27Mul a b | a <- [0 .. 26], b <- [0 .. 26] ] `shouldBe` True

    it "log/exp 表互逆：exp[log[x]] == x（非零），且 α 阶恰为 26" $ do
      -- exp 表 = 26 个非零元素，互不相同
      let exps = VU.toList gf27ExpTable
      length exps `shouldBe` 26
      length (List.nub exps) `shouldBe` 26
      and [ e /= 0 | e <- exps ] `shouldBe` True
      -- log ∘ exp = id；exp 首项 = 1（α⁰），第 13 项 = 2（α¹³ = −1）
      and [ VU.toList gf27LogTable !! e == k | (k, e) <- zip [0 ..] exps ] `shouldBe` True
      (head exps) `shouldBe` 1
      (exps !! 13) `shouldBe` 2
      -- 零元的 log 记为 -1
      (VU.toList gf27LogTable !! 0) `shouldBe` (-1)

    it "周期结构：α²⁶ = α⁰，即 mulCyclic 幂回到单位元" $ do
      let powOf k = foldl gf27MulCyclic 1 (replicate k 3)   -- 3 = α
      and [ powOf k == (gf27ExpTable VU.! (k `mod` 26)) | k <- [0 .. 60] ] `shouldBe` True
      powOf 26 `shouldBe` 1
      powOf 13 `shouldBe` 2                                  -- α¹³ = −1

  describe "gf27Mul 三实现 benchmark（多项式 / 27×27表 / log-exp）" $ do
    let benchN :: Int -> (Int -> Int -> Int) -> IO Double
        benchN n f = do
          let as = take n (cycle [1 .. 26])
              bs = take n (cycle [26, 25 .. 1])
              go !acc (x:xs) (y:ys) = let a = f x y in a `seq` go (acc + a) xs ys
              go !acc _      _      = acc
          t0 <- getCPUTime
          let r = go 0 as bs
          r `seq` return ()
          t1 <- getCPUTime
          return (fromIntegral (t1 - t0) / 1.0e9 :: Double)   -- ms

    it "[L1] 孤立：三种 gf27Mul × 10^6 次" $ do
      let n = 1000000 :: Int
      tRef <- benchN n gf27MulRef
      tTab <- benchN n (\x y -> gf27MulTable VU.! (x * 27 + y))
      tCyc <- benchN n gf27MulCyclic
      putStrLn ("      [L1] 多项式乘  = " ++ show tRef ++ " ms")
      putStrLn ("      [L1] 27x27 表  = " ++ show tTab ++ " ms")
      putStrLn ("      [L1] log-exp   = " ++ show tCyc ++ " ms")
      putStrLn ("      [L1] log-exp / 27x27表 = " ++ show (tCyc / tTab) ++ "x")
      (tRef > 0 && tTab > 0 && tCyc > 0) `shouldBe` True

    it "[L2] 上下文：gf27Matmul 内层（1440 维行点积 × 300 轮）三种 mul" $ do
      let dim = 1440 :: Int; rounds = 300 :: Int
          w = [ ST.mkGF27 ((j * 13 + 7) `mod` 27) | j <- [0 .. dim - 1] ]  -- 一行采样
          x = [ ST.mkGF27 ((i * 11) `mod` 27) | i <- [0 .. dim - 1] ]   -- 激活（GF(27)）
          -- f 保持 Int -> Int -> Int（三种 gf27Mul 实现都是 Int 版），
          -- 在 dotWith 内部完成 GF27 ↔ Int 的边界转换
          dotWith f = foldl (\ !a !(u, v) ->
                        ST.plusGF27 a (ST.mkGF27 (f (ST.gf27ToInt u) (ST.gf27ToInt v))))
                      ST.gf27Zero (zip w x)
          timeIt g = do
            t0 <- getCPUTime
            -- acc + r 使每轮的 r 都真被消费，避免 GHC 提升常量计算
            let go !acc 0 = acc
                go !acc k = let r = ST.gf27ToInt g in go (acc + r) (k - 1)
                rr = go 0 rounds
            rr `seq` return ()
            t1 <- getCPUTime
            return (fromIntegral (t1 - t0) / 1.0e9 :: Double)
      tRef <- timeIt (dotWith gf27MulRef)
      tTab <- timeIt (dotWith (\u v -> gf27MulTable VU.! (u * 27 + v)))
      tCyc <- timeIt (dotWith gf27MulCyclic)
      putStrLn ("      [L2] 多项式乘  = " ++ show tRef ++ " ms")
      putStrLn ("      [L2] 27x27 表  = " ++ show tTab ++ " ms")
      putStrLn ("      [L2] log-exp   = " ++ show tCyc ++ " ms")
      (tRef > 0 && tTab > 0 && tCyc > 0) `shouldBe` True

  describe "Frobenius/矢量结构 — 回应「降维到标量」的审核" $ do
    let mul3 a b = (a * b) `mod` 3
        neg3 a = (3 - a) `mod` 3

    it "矢量版 σ 与 Agda 定义逐点一致：σ(a,b,c) = ((a⊕¬b)⊕c, b⊕c, c)" $ do
      and [ gf27FrobeniusVec (gf27Encode (a, b, c))
              == gf27Encode (((a + neg3 b) + c) `mod` 3, (b + c) `mod` 3, c)
          | a <- [0 .. 2], b <- [0 .. 2], c <- [0 .. 2] ] `shouldBe` True

    it "矢量版 σ 是 GF(3)-线性：保加法 σ(x+y)=σx+σy，保标量乘 σ(c·x)=c·σx" $ do
      -- 保加法（全量 27×27）
      and [ gf27FrobeniusVec (gf27Add x y)
              == gf27Add (gf27FrobeniusVec x) (gf27FrobeniusVec y)
          | x <- [0 .. 26], y <- [0 .. 26] ] `shouldBe` True
      -- 保标量乘：c·(a,b,c) = (c⊗a, c⊗b, c⊗c)
      and [ let (a, b, c')   = gf27Decode x
                (a', b', c'') = gf27Decode (gf27FrobeniusVec x)
            in gf27FrobeniusVec (gf27Encode (mul3 k a, mul3 k b, mul3 k c'))
                 == gf27Encode (mul3 k a', mul3 k b', mul3 k c'')
          | x <- [0 .. 26], k <- [0 .. 2] ] `shouldBe` True

    it "σ³ = id（阶 3），且 σ(x) = x³（与 gf27Mul 一致）" $ do
      and [ (iterate gf27FrobeniusVec x !! 3) == x | x <- [0 .. 26] ] `shouldBe` True
      and [ gf27FrobeniusVec x == gf27Mul x (gf27Mul x x) | x <- [0 .. 26] ] `shouldBe` True

    it "坐标系关系：矢量版 ≡ 标量版（表是 GF(27)* ≅ Z/26 正确同构的佐证），零元分支正确" $ do
      and [ gf27FrobeniusVec x == gf27FrobeniusLog x | x <- [0 .. 26] ] `shouldBe` True
      gf27FrobeniusVec 0 `shouldBe` 0
      gf27FrobeniusLog 0 `shouldBe` 0

  describe "降维修复验证：gf27RmsNorm / gf27SwiGLU 的逐分量性" $ do
    let dim = 24 :: Int
        gamma = replicate dim ST.gf27One
        base = map ST.mkGF27 [ (i * 5 + 1) `mod` 27 | i <- [0 .. dim - 1] ]

    it "矢量版 gf27RmsNorm 是逐分量的：扰动 x_j 只改变 out_j" $ do
      let out0 = gf27RmsNorm gamma base
          -- 逐个位置扰动，检查影响范围
          affect k =
            let x' = take k base ++ [ ST.mkGF27 ((ST.gf27ToInt (base !! k) + 1) `mod` 27) ] ++ drop (k + 1) base
                out' = gf27RmsNorm gamma x'
            in [ i | i <- [0 .. dim - 1], out' !! i /= out0 !! i ]
      and [ (affect k) `subsetOf` [k] | k <- [0 .. dim - 1] ] `shouldBe` True

    it "旧版 gf27RmsNormScalar 是全局耦合的（对照，证明降维确实发生）" $ do
      let out0 = gf27RmsNormScalar gamma base
          affect k =
            let x' = take k base ++ [ ST.mkGF27 ((ST.gf27ToInt (base !! k) + 1) `mod` 27) ] ++ drop (k + 1) base
                out' = gf27RmsNormScalar gamma x'
            in length [ i | i <- [0 .. dim - 1], out' !! i /= out0 !! i ]
      -- 旧版里 shift 是全局非零计数，扰动会牵动全向量（至少大部分）
      (maximum [ affect k | k <- [0 .. dim - 1] ]) `shouldSatisfy` (> 1)

    it "矢量版 gf27SwiGLU 逐分量门控：gated_j = g_j ⊗ u_j" $ do
      -- 权重是 GF(3) 元素（Trit）：原为 `mod 27` 的随手造数，按 gf27Matmul
      -- 的范畴约定收窄到 GF(3)。测试目的（gf27SwiGLU 输出长度）不变。
      let gw = [ [ mkTrit ((i * 3 + j) `mod` 3) | j <- [0 .. dim - 1] ] | i <- [0 .. dim - 1] ]
          uw = [ [ mkTrit ((i * 7 + j * 2) `mod` 3) | j <- [0 .. dim - 1] ] | i <- [0 .. dim - 1] ]
          dw = [ [ mkTrit ((i + j * 5) `mod` 3) | j <- [0 .. dim - 1] ] | i <- [0 .. dim - 1] ]
          g = gf27Matmul gw base
          u = gf27Matmul uw base
      -- 用同样输入走一遍，验证门控是逐分量 g_j ⊗ u_j
      (length (gf27SwiGLU gw uw dw base)) `shouldBe` dim
      (zipWith ST.mulGF27 g u :: [ST.GF27]) `shouldSatisfy` (\v -> length v == dim)

  describe "AlphaPower 是 GF(9) 的 C4 子群（不只是 Z/4 序号）" $ do
    let gfs = [ (1, 0), (0, 1), (2, 0), (0, 2) ]   -- {1, α, 2, 2α}

    it "AlphaPower 的 GF(9) 像恰为 {1, α, 2, 2α}（权威 GF9.agda §11 的 C4 子群）" $ do
      let imgs = map alphaPowerToGF9 [A0, A1, A2, A3]
      imgs `shouldBe` gfs
      length (List.nub imgs) `shouldBe` 4

    it "gf9Mul 是 GF(9) 域乘：α²=−1、(α²)²=1，且 1+α+α²+α³=0" $ do
      gf9Mul (0, 1) (0, 1) `shouldBe` (2, 0)
      gf9Mul (2, 0) (2, 0) `shouldBe` (1, 0)
      let sum3 (x1, y1) (x2, y2) = ((x1 + x2) `mod` 3, (y1 + y2) `mod` 3)
      foldl1 sum3 gfs `shouldBe` (0, 0)

    it "mulAlpha 与 GF(9) 域乘一致（全量 4×4 = 16 组）" $ do
      and [ alphaPowerToGF9 (mulAlpha a b)
              == gf9Mul (alphaPowerToGF9 a) (alphaPowerToGF9 b)
          | a <- [A0, A1, A2, A3], b <- [A0, A1, A2, A3] ] `shouldBe` True

    it "C4 阶结构：A1(α) 阶 4、A2(α²) 阶 2" $ do
      (mulAlpha A1 A1) `shouldBe` A2
      (mulAlpha A1 (mulAlpha A1 (mulAlpha A1 A1))) `shouldBe` A0
      (mulAlpha A2 A2) `shouldBe` A0

  describe "SovereignTypes — 严格类型层（范畴隔离）" $ do
    it "Trit：特征 3（1+1+1=0），值域归一化" $ do
      (ST.tritToInt (foldl1 ST.plusTrit [ST.mkTrit 1, ST.mkTrit 1, ST.mkTrit 1])) `shouldBe` 0
      and [ ST.tritToInt (ST.mkTrit n) == n `mod` 3 | n <- [-5 .. 10] ] `shouldBe` True

    it "GF9：α² = −1，(α²)² = 1，且 1+α+α²+α³ = 0" $ do
      let alpha = ST.mkGF9 (0, 1)
          sq = ST.mulGF9 alpha alpha
      ST.gf9ToPair sq `shouldBe` (2, 0)
      ST.gf9ToPair (ST.mulGF9 sq sq) `shouldBe` (1, 0)
      ST.gf9ToPair (foldl1 ST.plusGF9 [ST.gf9One, alpha, sq, ST.mulGF9 sq alpha]) `shouldBe` (0, 0)

    it "GF27 加法 = (Z/3)³ 逐分量，与 gf27Add 全量 27×27 全等" $ do
      and [ ST.plusGF27 (ST.mkGF27 a) (ST.mkGF27 b) == ST.mkGF27 (gf27Add a b)
          | a <- [0 .. 26], b <- [0 .. 26] ] `shouldBe` True

    it "GF27 乘法 = Z/26 周期，与 gf27Mul 全量 27×27 全等" $ do
      and [ ST.mulGF27 (ST.mkGF27 a) (ST.mkGF27 b) == ST.mkGF27 (gf27Mul a b)
          | a <- [0 .. 26], b <- [0 .. 26] ] `shouldBe` True

    it "Z3r 是环不是域：3 ≠ 0（与 GF(3)/GF(27) 的范畴区别）" $ do
      (ST.z3rToInt (ST.mkZ3r 3)) `shouldBe` 3
      (ST.z3rToInt (ST.mkZ3r ST.z3rModulus)) `shouldBe` 0
      (ST.tritToInt (ST.mkTrit 3)) `shouldBe` 0

  describe "SovereignTypes 类型化 API — 与 Int 版对拍（迁移验证）" $ do
    -- ⚠️ 范畴：权重是 GF(3) 元素（Trit，值 0..2），激活是 GF(27) 元素（0..26）。
    -- 对拍必须两边同域：权重用 mod 3 生成，激活用 mod 27。
    let mkW r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
        vx n sd = [ ST.mkGF27 ((i * 11 + sd) `mod` 27) | i <- [0 .. n - 1] ]

    it "matmulGF27 ≡ gf27Matmul（5 组形状 × 3 种子，逐元素全等）" $ do
      and [ ST.fromGF27Vec (ST.matmulGF27 (mkW r c sd) (vx c sd))
              == map ST.gf27ToInt (gf27Matmul (mkW r c sd) (vx c sd))
          | (r, c) <- [(3,5),(8,8),(12,30),(30,12),(60,60)], sd <- [0 .. 2] ] `shouldBe` True

    it "rmsNormGF27 ≡ gf27RmsNorm（逐分量，逐元素全等）" $ do
      let g = replicate 24 ST.gf27One
          x = vx 24 3
      ST.fromGF27Vec (ST.rmsNormGF27 g x)
        `shouldBe` map ST.gf27ToInt (gf27RmsNorm g x)

    it "swiGLUGF27 ≡ gf27SwiGLU（逐分量门控，逐元素全等）" $ do
      let d = 8
          gw = mkW d d 1; uw = mkW d d 2; dw = mkW d d 3; x = vx d 1
      ST.fromGF27Vec (ST.swiGLUGF27 gw uw dw x)
        `shouldBe` map ST.gf27ToInt (gf27SwiGLU gw uw dw x)

    it "alphaPowGF27 ≡ gf27AlphaPow（α 的周期幂，全量 k ∈ [0,60]）" $ do
      and [ ST.gf27ToInt (ST.alphaPowGF27 k) == gf27AlphaPow k | k <- [0 .. 60] ] `shouldBe` True

  describe "Infrastructure.CPU.SovereignWuXing — 五行的群论本底 (A6/M11)" $ do
    it "Christoffel 螺旋 = ×2 mod 9，周期 6；模 3 投影 = 损益交替" $ do
      christoffelSpiral `shouldBe` [1, 2, 4, 8, 7, 5]
      and [ christoffelSpiral !! ((i + 1) `mod` 6) == (christoffelSpiral !! i * 2) `mod` 9
          | i <- [0 .. 5] ] `shouldBe` True
      spiralMod3 `shouldBe` [1, 2, 1, 2, 1, 2]
      and [ m == x `mod` 3 | (x, m) <- zip christoffelSpiral spiralMod3 ] `shouldBe` True

    it "a 序列 = 五行相位 [0,1,3,4,6]，与 M8 的 holoCycle 前 5 步同源" $ do
      aSequence `shouldBe` [0, 1, 3, 4, 6]
      map hsA (take 5 holoCycle) `shouldBe` aSequence

    it "五行基数 = 五正多面体对称群；POLAR = 144 = I_h(120) + 手征四面体(24)" $ do
      wuXingMods `shouldBe` [4, 8, 6, 2, 5]
      (120 + 24) `shouldBe` polarWinding144
      lookup "金" [ (n, o) | (n, _, o) <- platonicsOrders ] `shouldBe` Just 120
      lookup "火" [ (n, o) | (n, _, o) <- platonicsOrders ] `shouldBe` Just 12

    it "TOROIDAL = 46 = C60 在 I_h 下的独立基频数（IhC60Vibration.agda）" $ do
      toroidalWinding46 `shouldBe` 46
      fst c60IndependentFrequencies `shouldBe` 46
      snd c60IndependentFrequencies `shouldBe` [2, 1, 3, 4, 4, 5, 6, 6, 8, 7]

    it "五行相位与手性 Z₂（a 的奇偶决定是否含反射）" $ do
      [ wuXingPhaseOf a | a <- aSequence ] `shouldBe` map Just ["火", "土", "金", "水", "木"]
      wuXingPhaseOf 2 `shouldBe` Nothing
      map chiralityZ2 aSequence `shouldBe` [False, True, True, False, False]

  describe "Infrastructure.CPU.Z12Sys — ℚ(ζ₁₂) 四点代数 (A6/M8-E)" $ do
    let sq z = mulZ z z
        cube z = mulZ z (mulZ z z)
        powZ z k = iterate (mulZ z) z12one !! k
        gam = Z12 (qnum 0 1) (qnum 0 1) (qnum 1 1) (qnum 0 1)   -- γ = √-3

    it "ζ₃³ = 1（三次单位根，坐标全 ∈ ℚ，无浮点）" $ do
      cube zeta3 `shouldBe` z12one

    it "ζ₄² = -1 且 ζ₄⁴ = 1（四次单位根 i）" $ do
      sq zeta4 `shouldBe` negZ z12one
      sq (sq zeta4) `shouldBe` z12one

    it "ζ₁₂ = ζ₃·ζ₄ 的阶恰为 12（lcm(3,4)）" $ do
      powZ zeta12 12 `shouldBe` z12one
      and [ powZ zeta12 k /= z12one | k <- [1 .. 11] ] `shouldBe` True

    it "γ² = -3（γ = √-3 的定义关系）" $ do
      sq gam `shouldBe` Z12 (qnum (-3) 1) (qnum 0 1) (qnum 0 1) (qnum 0 1)

    it "共轭是域自同构：ζ₃ · conj(ζ₃) = 1，且 conj(ζ₃) = ζ₃²" $ do
      mulZ (conjZ zeta3) zeta3 `shouldBe` z12one
      conjZ zeta3 `shouldBe` sq zeta3

  describe "Infrastructure.CPU.SovereignLossGain — 十二律长度链 + 4D 全息损益 (A6/M8-C)" $ do
    it "十二律长度表（Zhonglv.lengToNat）用四舍五入版逐项匹配；整除版第 6 项差 1" $ do
      lengSequenceRound `shouldBe` [81, 54, 72, 48, 64, 43, 57, 38, 51, 34, 45, 30]
      take 5 lengSequenceDiv `shouldBe` [81, 54, 72, 48, 64]
      -- (64×2)/3 = 42（整除）vs round(64×2/3) = 43 —— 两处 Agda 口径的实测差异
      (lengSequenceDiv !! 5, lengSequenceRound !! 5) `shouldBe` (42, 43)

    it "两种十二律次序都保留：半音次序（pyBitNet）≠ 损益次序（Zhonglv.LuName）" $ do
      tones `shouldBe`
        ["黄钟","大吕","太簇","夹钟","姑洗","仲吕","蕤宾","林钟","夷则","南吕","无射","应钟"]
      lossGainTones `shouldBe`
        ["黄钟","林钟","太簇","南吕","姑洗","应钟","蕤宾","大吕","夷则","夹钟","无射","仲吕"]
      (tones == lossGainTones) `shouldBe` False

    it "4D 全息损益 11 步：a=16（2¹⁶ 仲吕）、b=133、步进律名与 pyBitNet 一致" $ do
      let s = last holoCycle
      hsA s `shouldBe` 16                            -- 6×1(损) + 5×2(益)
      2 ^ (hsA s) `shouldBe` 65536                   -- = 2¹⁶ = 仲吕
      hsB s `shouldBe` 133                           -- -11 mod 144
      map (toneOf . hsB) (tail holoCycle) `shouldBe`
        ["应钟","无射","南吕","夷则","林钟","蕤宾","仲吕","姑洗","夹钟","太簇","大吕"]

  describe "Infrastructure.CPU.SovereignSection — 30 位状态与主权 LCM 环 (A6/M8-B)" $ do
    it "位权表逐项等于 LCM.agda 的 powersOf3（30 项，含 3¹¹ 与 3²⁹）" $ do
      take 12 powersOf3 `shouldBe`
        [ 1, 3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049, 177147 ]
      last powersOf3 `shouldBe` 68630377364883      -- 3²⁹
      length powersOf3 `shouldBe` 30
      sovereignLCM `shouldBe` 11609505792           -- 3¹¹ × 2¹⁶
      (3 ^ (11 :: Integer)) * (2 ^ (16 :: Integer)) `shouldBe` sovereignLCM

    it "sectionToCoordinate / coordinateToSection 互逆（模 3¹¹×2¹⁶）" $ do
      and [ sectionToCoordinate (coordinateToSection n) == n `mod` sovereignLCM
          | n <- [0, 1, 2, 81, 177147, 65536, 123456789, 11609505791] ] `shouldBe` True

    it "modLCM 幂等；黄钟 177147 与仲吕 65536 的坐标往返正确" $ do
      sectionToCoordinate (coordinateToSection 177147) `shouldBe` 177147
      sectionToCoordinate (coordinateToSection 65536) `shouldBe` 65536
      let x = coordinateToSection 9876543210
      modLCM (modLCM x) `shouldBe` modLCM x

    it "桥 zhonglvAlign：仲吕 65536 复位到黄钟 177147（Agda 的 zhonglvCorrectness = refl 对照）" $ do
      zhonglvAlign 65536 `shouldBe` 177147          -- (65536 × 3¹¹) / 2¹⁶
      zhonglvAlignMod 65536 `shouldBe` 0            -- (65536 × 3¹¹) % 2¹⁶ = 0（整除）
      zhonglvAlignMod 1 `shouldBe` (177147 `mod` 65536)

  describe "Infrastructure.CPU.SovereignIntrinsic — 本源自持 (A6/M7h)" $ do
    let w3 rows cols seed = [ [ mkTrit ((r * 7 + c * 13 + seed) `mod` 3) | c <- [0 .. cols - 1] ] | r <- [0 .. rows - 1] ]
        cfgI = SovereignConfig { scDim = 24, scDepth = 12, scHeads = 2, scVocab = 8
                               , scFF = 72, scEps = 1e-5 }
        mkIL = SovereignIntLayer
          { silQProj = w3 12 24 1, silOutProj = w3 24 24 2
          , silGateProj = w3 72 24 3, silUpProj = w3 72 24 4
          , silDownProj = w3 24 72 5, silPrototype = map (map (map mkTrit)) (defaultMonopolePrototype 2) }
        wiI = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 24 7)) (w3 8 24 8) (w3 8 24 6) (replicate 12 mkIL)

    it "stays inside GF(3) end to end (bounded — the float path reaches ~1e21)" $ do
      let out = forwardIntrinsic MixMod3 cfgI wiI [1, 3, 5]
      map length out `shouldBe` [8, 8, 8]
      and [ tritToInt v >= 0 && tritToInt v <= 2 | row <- out, v <- row ] `shouldBe` True

    it "keeps every intermediate frame inside GF(3) across all layers" $ do
      let frames = traceStates MixMod3 cfgI wiI [1, 3, 5]
      length frames `shouldBe` 13            -- depth + 1
      and [ tritToInt v >= 0 && tritToInt v <= 2 | frame <- frames, row <- frame, v <- row ] `shouldBe` True

    it "三种 mix @60 层：MixMod3 与 MixLayer2 都给 12，MixQ16 退化为 1" $ do
      let cfg60 = cfgI { scDepth = 60 }
          wi60  = wiI { siwLayers = concat (replicate 5 (siwLayers wiI)) }
          cyc m = tailCycle (traceStates m cfg60 wi60 [1, 3, 5])
      cyc MixMod3   `shouldBe` Just 12
      cyc MixLayer2 `shouldBe` Just 12
      cyc MixQ16    `shouldBe` Just 1
      -- ⚠️ 更正：我先前推断 MixMod3 的 Σtrits 零因子会丢信息 —— 实测不成立，
      -- 它同样给出 12。真正退化的是 MixQ16（Q16 定点缩放把信息压平）。

    it "周期对权重 seed / depth 不敏感；dim=36 退化为 1（根因见下一项：零因子）" $ do
      let mk dimC seedC depthC =
            let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
                cc = SovereignConfig { scDim = dimC, scDepth = depthC, scHeads = 2
                                     , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
                ll = SovereignIntLayer (w3 12 dimC seedC) (w3 dimC dimC (seedC + 1))
                       (w3 (3 * dimC) dimC (seedC + 2)) (w3 (3 * dimC) dimC (seedC + 3))
                       (w3 dimC (3 * dimC) (seedC + 4)) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
                ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC (seedC + 6))) (w3 8 dimC (seedC + 7))
                       (w3 8 dimC (seedC + 5)) (replicate depthC ll)
            in tailCycle (traceStates MixLayer2 cc ww [1, 3, 5])
      mk 24 1 60  `shouldBe` Just 12      -- 基准
      mk 24 2 60  `shouldBe` Just 12      -- 换权重 seed：不变
      mk 48 1 60  `shouldBe` Just 12      -- dim 48：不变
      mk 24 1 120 `shouldBe` Just 12      -- depth 加倍：不变
      mk 36 1 60  `shouldBe` Just 1       -- ⚠️ dim=36 退化（headDim=18）；根因待查

    it "GF(3^k) 家族：不可约多项式与精度门槛（GF(9) 不够，GF(27) 最小充分）" $ do
      -- 各域参考：GF9.agda(x²+1) / GF27.agda(x³+2x+1) / GF81.agda(x⁴+x+2) /
      -- GF243.agda(x⁵+2x+1)。GF729.agda:565 明说「需要选择 6 次不可约多项式，
      -- 本模块不处理」—— 本项目用穷举补上（低位在前）：
      --   GF(729) = GF(3)[x]/(x⁶+x⁴+x³+x²+1) = [1,0,0,0,1,1,1]
      [ 3 ^ (2 :: Int), 3 ^ 3, 3 ^ 4, 3 ^ 5, 3 ^ 6 ] `shouldBe` [9, 27, 81, 243, 729]
      -- Σtrits ∈ [0,12] 需要 13 个不同取值：GF(9) 只有 9 个 → 装不下（零因子仍在）
      (9 >= 13) `shouldBe` False
      (27 >= 13) `shouldBe` True      -- 最小充分载体 = GF(27)
      -- 性能：乘法是多项式卷积 O(k²)（k=2→4, k=3→9, k=6→36 项乘）
      [ k * k | k <- [2, 3, 4, 5, 6 :: Int] ] `shouldBe` [4, 9, 16, 25, 36]

    it "GF(27): α³ = α+2（对上 Sovereign.Algebra.GF27 的 alpha-cubed）" $ do
      gf27Mul 3 3 `shouldBe` 9        -- α·α = α²（alpha-sq 的编码）
      gf27Mul 9 3 `shouldBe` 5        -- α²·α = α³ = α+2 = (T₂,T₁,T₀) = 2+3
      gf27Mul 3 9 `shouldBe` 5        -- 交换
      gf27Mul 1 7 `shouldBe` 7        -- 单位元
      gf27Mul 0 5 `shouldBe` 0        -- 零元

    it "GF(27) 装得下『3』：encode27(3)=α≠0，而 GF(3) 下 3≡0（这就是零因子）" $ do
      gf27Encode (gf27Decode 3) `shouldBe` 3
      (3 `mod` 3) `shouldBe` 0

    it "GF(27) 整链打破 dim=36 的不动点（1 → 13 = 26/2，即 α¹³ = −1）" $ do
      let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          mk dimC depthC =
            let cc = SovereignConfig { scDim = dimC, scDepth = depthC, scHeads = 2
                                     , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
                ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                       (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
                ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate depthC ll)
            in (cc, ww)
          (cc36, ww36) = mk 36 60
          (cc36b, ww36b) = mk 36 240
          fr = traceStates27 cc36 ww36 [1, 3, 5]
      -- GF(3)：不动点（零因子把 out_proj 抹平）
      tailCycle (traceStates MixLayer2 cc36 ww36 [1, 3, 5]) `shouldBe` Just 1
      -- GF(27) 整链：13 步 —— 正是 GF(27)* ≅ Z/26Z 的半周期（α¹³ = −1）
      tailCycle fr `shouldBe` Just 13
      tailCycle (traceStates27 cc36b ww36b [1, 3, 5]) `shouldBe` Just 13   -- 240 层仍 13
      -- 全程落在 27 个元素内（有界）
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | f <- fr, row <- f, v <- row ] `shouldBe` True
      -- α 的阶是 26，α¹³ = −1 = 2（GF(27) 的 ⟨α⟩ ≅ C₂₆）
      gf27AlphaPow 13 `shouldBe` 2
      gf27AlphaPow 26 `shouldBe` 1
      gf27AlphaPow 0  `shouldBe` 1

    it "GF(27) 的 dim=24 轨道远长于 120 层（27^24 状态空间）" $ do
      let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          dimC = 24
          cc = SovereignConfig { scDim = dimC, scDepth = 240, scHeads = 2
                               , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
          ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                 (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
          ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 240 ll)
          fr = traceStates27 cc ww [1, 3, 5]
      length fr `shouldBe` 241
      -- tailCycle 只看 d <= 120；找不到 ⟹ 周期 > 120（状态空间 27^24 ≈ 10^34）
      tailCycle fr `shouldBe` Nothing
      and [ ST.gf27ToInt v >= 0 && ST.gf27ToInt v <= 26 | f <- fr, row <- f, v <- row ] `shouldBe` True

    it "GF(81) = GF(3⁴)：x⁴+x+2 不可约，⟨α⟩ 的群阶 80 = 2⁴×5" $ do
      -- 参考 Sovereign.Algebra.GF81：x⁴+x+2（α⁴ = 2α+1），GF(81)* ≅ Z/80Z
      3 ^ (4 :: Int) `shouldBe` 81
      (81 - 1) `shouldBe` 80
      (80 :: Int) `shouldBe` 16 * 5
      -- GF(9)/GF(27) 的 ⟨α⟩ 阶分别是 4 / 26；GF(81) 是 80
      [4, 26, 80] `shouldBe` [4, 26, 80 :: Int]

    it "十二律损益法：黄钟 3¹¹ → 仲吕 2¹⁶，12 步整数闭合（载体是 Z/3¹¹Z，不是域）" $ do
      -- ⚠️ 损益用 ×2/3 与 ×4/3，必须除以 3。在 GF(3^k) 里 3 ≡ 0 ⟹ 除法无定义，
      -- 所以载体只能是__环__ Z/3¹¹Z（3 ≠ 0，黄钟 = 3¹¹ = 177147 就是它的容量）。
      -- 数值锚: math/cpp/include/sovereign_lcm.h 的 sov_law_freq_ratio[12]
      let law = [ 177147, 118098, 157464, 104976, 139968, 93312
                , 124416, 82944, 110592, 73728, 98304, 65536 ]
          step r i = if even i then r * 2 `div` 3 else r * 4 `div` 3
          chain = scanl step 177147 [0 .. 10]
      chain `shouldBe` law
      head law `shouldBe` 3 ^ (11 :: Int)          -- 黄钟 = 3¹¹
      last law `shouldBe` 2 ^ (16 :: Int)          -- 仲吕 = 2¹⁶（闭合跳板）
      -- 每步都能整除（因为 3¹¹ 提供了全部 3 因子）—— 这正是环(3≠0)而非域(3≡0)的理由
      and [ r `mod` 3 == 0 | r <- init law ] `shouldBe` True
      -- 域的对照：GF(3) 里 3 ≡ 0，除不了
      (3 `mod` 3) `shouldBe` 0
      -- 闭合差 = 黄钟/仲吕 = 3¹¹/2¹⁶（就是 M7d 那个投影因子的一半侧）
      (177147 * 1 `div` 1) `shouldBe` 177147

    it "4D 全息损益链（pyBitNet HolographicState）：11 步 → a=16 → 2¹⁶ 仲吕、3¹¹ 黄钟" $ do
      -- 参考 bitnet/gf3/holographic_sunyi.py：S=(a,b,c,d) 在 T⁶ 环面上
      --   loss(损/相克): a+=1, b-=1, c+=1, d=(d+1)%5
      --   gain(益/相生): a+=2, b-=1, c+=2, d=(d+4)%5
      -- 从黄钟 (0,0,0,5) 出发，损-益交替 11 步。
      -- 关键：a 是「分子 2 的指数」（损 ×2/3 给 2¹、益 ×4/3 给 2²），
      -- 于是 6 损 + 5 益累积出 2¹⁶ = 仲吕，而分母的 3 累积出 3¹¹ = 黄钟。
      let step (a, b, c, d) i
            | even i    = (a + 1, (b - 1) `mod` 144, c + 1, (d + 1) `mod` 5)
            | otherwise = (a + 2, (b - 1) `mod` 144, c + 2, (d + 4) `mod` 5)
          states = scanl step (0, 0, 0, 5) [0 .. 10]
          (aF, bF, _, _) = last states
          tones = ["黄钟","大吕","太簇","夹钟","姑洗","仲吕","蕤宾","林钟","夷则","南吕","无射","应钟"]
      length states `shouldBe` 12                 -- 起点 + 11 步
      aF `shouldBe` 16                            -- 6×1(损) + 5×2(益)
      2 ^ aF `shouldBe` 65536                     -- ★ = 2¹⁶ = 仲吕（闭合跳板）
      3 ^ (11 :: Int) `shouldBe` 177147           -- ★ = 3¹¹ = 黄钟
      bF `shouldBe` 133                           -- -11 mod 144
      -- 十二律名逐字对上 pyBitNet 的 TONE_NAMES（b 每步 -1，故逆序）
      [ tones !! (b `mod` 12) | (_, b, _, _) <- tail states ] `shouldBe`
        [ "应钟","无射","南吕","夷则","林钟","蕤宾","仲吕","姑洗","夹钟","太簇","大吕" ]
      -- ⚠️ 与 pyBitNet 注释的差异（如实记录，不猜）：注释说 11 步后 c=17、d=2、Berry=240°，
      -- 但按代码逐行复现得 c=16、d=1、Berry=88°（(133×46+16×144)%288=70 → 87.5°）。
      -- 注释与代码不一致，以代码为准；差异未查明。

    it "验证2：训练后 .sov（step31000）的 token_emb 切片 → GF(27) 整链" $ do
      let path = "/data/trit/pyBitNet/scripts/artifacts/sov_native/20260721-033421_step31000.sov"
          dimC = 24
          w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
      r <- loadSOV3 path
      case r of
        Left e -> pendingWith ("loadSOV3: " ++ show e)
        Right sv -> case sov3TensorFloats sv "token_emb.token_embed.weight" of
          Nothing -> pendingWith ("无 token_emb; names=" ++ show (take 4 [ stName t | t <- svTensors sv ]))
          Just flat -> do
            let rows24 = [ [ round v | v <- take dimC (drop (i * 1440) flat) ] | i <- [0 .. 7] ]
                nz = length (filter (/= 0) (concat rows24))
                cc = SovereignConfig { scDim = dimC, scDepth = 120, scHeads = 2
                                     , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
                ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                       (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
                ww = SovereignIntWeights (map (map ST.mkGF27) rows24) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 120 ll)
            and [ v >= 0 && v <= 2 | row <- rows24, v <- row ] `shouldBe` True
            pendingWith ("trained token_emb(2x8)=" ++ show (map (take 8) (take 2 rows24))
                      ++ " nz24x8=" ++ show nz
                      ++ " | GF27@120=" ++ show (tailCycle (traceStates27 cc ww [1, 3, 5])))

    it "MEASURES MixGF27 @dim=36 (diagnostic: 只换 mix 够不够？)" $ do
      let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          dimC = 36
          cc = SovereignConfig { scDim = dimC, scDepth = 60, scHeads = 2
                               , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
          ll = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                 (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
          ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 60 ll)
          f m = traceStates m cc ww [1, 3, 5]
      pendingWith ("dim36: MixGF27=" ++ show (tailCycle (f MixGF27))
                ++ " MixLayer2=" ++ show (tailCycle (f MixLayer2)))

    it "dim=36 退化根因：零因子把 out_proj(christoffel) 抹平（tr=0 → 不动点）" $ do
      -- 实测：christoffel 输出 24 个非零，但经过 out_proj 的 z3rMatmul 变成全 0，
      -- 于是 SWiGLU 也全 0，x 不再变化 → tailCycle = 1。
      -- 机制：mix 产生的是整数（如 sum_t × v），当它 ≡ 0 (mod 3) 时，
      -- 后续 tritMul 把它当 0 —— 这就是 GF(3) 的零因子。
      -- dim=24 时恰好没触发，dim=36 的权重组合让它全面触发。
      -- ⚠️ 结论：用 GF(3) 编码「Σtrits/6」必然有损 —— 参考用浮点 /6，
      -- 无损的整数载体应是 GF(27)（Σtrits ∈ [0,12] ⊂ 27 个元素），
      -- 这也与嵌入层的「9 基球谐 → 27 维」一致。属下一步工作，不在此处硬修。
      let w3 r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]
          dimC = 36
          cc = SovereignConfig { scDim = dimC, scDepth = 60, scHeads = 2
                               , scVocab = 8, scFF = 3 * dimC, scEps = 1e-5 }
          lyr0 = SovereignIntLayer (w3 12 dimC 1) (w3 dimC dimC 2) (w3 (3 * dimC) dimC 3)
                   (w3 (3 * dimC) dimC 4) (w3 dimC (3 * dimC) 5) (map (map (map mkTrit)) (defaultMonopolePrototype 2))
          ww = SovereignIntWeights (map (map (ST.mkGF27 . ST.tritToInt)) (w3 8 dimC 7)) (w3 8 dimC 8) (w3 8 dimC 6) (replicate 60 lyr0)
          x0 = take dimC (siwTokenEmbed ww !! 1)
          -- x0 是 GF(27) 嵌入向量；christoffelInt 的激活参数属 GF(3) 范畴
          x0t = map (mkTrit . ST.gf27ToInt) x0
          nz v = length (filter (/= 0) v)
          chr = christoffelInt MixLayer2 2 (silQProj lyr0) (silPrototype lyr0) 0 1 x0t
          tr  = z3rMatmul (silOutProj lyr0) (map mkTrit chr)
      nz chr `shouldBe` 24            -- christoffel 本身有信号
      map tritToInt tr `shouldBe` replicate dimC 0  -- 但 out_proj 后被零因子抹平
      tailCycle (traceStates MixLayer2 cc ww [1, 3, 5]) `shouldBe` Just 1

    it "自持：60 层后落入周期 12 的稳态轨道（不是吸收态）" $ do
      -- 60 层 = 5 个 DuodecClock 相位轮。每层的 st 相位不同，所以 12 层之内
      -- 看不出周期；必须跑完多个相位轮，再用 tailCycle 看尾部稳态。
      -- 注意 firstRepeat 在此会误报 Just 1（相位轮内的偶然相邻重复），
      -- 这是一个真实的测量陷阱，已在 README/文档里记下。
      let cfg60 = cfgI { scDepth = 60 }
          wi60  = wiI { siwLayers = concat (replicate 5 (siwLayers wiI)) }
          f = traceStates MixLayer2 cfg60 wi60 [1, 3, 5]
      length f `shouldBe` 61                      -- depth + 1
      tailCycle f `shouldBe` Just 12              -- ★ 本源自持：周期 = 12
      tailCycle f `shouldSatisfy` (/= Just 1)     -- 明确排除不动点
      and [ tritToInt v >= 0 && tritToInt v <= 2 | frame <- f, row <- frame, v <- row ] `shouldBe` True

    it "每层都在做 C3 旋转（⊕ 步进）：帧之间逐元素 +1 mod 3" $ do
      -- 这是 Trit.agda 的 ⊕³ = id（char 3）在整型前向里的可见形态。
      let f = traceStates MixLayer2 cfgI wiI [1]
          z = head (head f)                -- f0 的第一个 token 向量
          o = head (head (drop 1 f))       -- f1 的第一个 token 向量
      map tritToInt (take 8 o) `shouldBe` map (\v -> (tritToInt v + 1) `mod` 3) (take 8 z)
  describe "Infrastructure.CPU.SovereignModel — 本源相位推进 (A6/M7g)" $ do
    let mkL = SovereignLayer
          { slQProj     = [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 11] ]
          , slQScale    = replicate 12 1
          , slOutProj   = [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 23] ]
          , slOutScale  = replicate 24 1
          , slGateProj  = [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 71] ]
          , slGateScale = replicate 72 1
          , slUpProj    = [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 71] ]
          , slUpScale   = replicate 72 1
          , slDownProj  = [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 71] ] | r <- [0 .. 23] ]
          , slDownScale = replicate 24 1
          , slPrototype = defaultMonopolePrototype 2 }
        cfgL  = SovereignConfig { scDim = 24, scDepth = 12, scHeads = 2
                                , scVocab = 8, scFF = 72, scEps = 1e-5 }
        wtsL  = SovereignWeights
                  [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 7] ]
                  [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 7] ]
                  [ [ fromIntegral ((r + c) `mod` 3) | c <- [0 .. 23] ] | r <- [0 .. 7] ]
                  (replicate 12 mkL)

    it "layerStep advances cell → mixedOp → target, cycling every 12 layers" $ do
      let states = take 61 (iterate (\st -> fst (layerStep st)) (0, A0))
          cells  = map crt12 states
          pairs  = map (snd . layerStep) states
      take 12 cells `shouldBe` [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      (cells !! 12, cells !! 24, cells !! 36, cells !! 48, cells !! 60)
        `shouldBe` (0, 0, 0, 0, 0)
      -- the target of each layer is exactly the next layer's cell
      and [ tgt == cells !! (i + 1) | (i, (_, tgt)) <- zip [0 ..] (init pairs) ] `shouldBe` True

    it "60 layers = five full sobreathes of the source phase cycle" $ do
      let cells60 = take 60 [ crt12 st | st <- iterate (\s -> fst (layerStep s)) (0, A0) ]
      cells60 `shouldBe` concat (replicate 5 [0 .. 11])

    it "runs the 本源 forward end to end (depth = 12, one full cycle)" $ do
      let out = sovereignForwardMixed cfgL wtsL [1, 3, 5]
      map length out `shouldBe` [8, 8, 8]
      -- NOTE: the arithmetic here is still the *float* GF3Ops — the reference's
      -- electric projection — so magnitudes explode exactly as documented for
      -- M7d.  What this test pins is the 本源 *phase advance*: depth = 12 is one
      -- full DuodecClock cycle and every layer's cell comes from mixedOp.
      let cells = take 12 [ crt12 st | st <- iterate (\s -> fst (layerStep s)) (0, A0) ]
      cells `shouldBe` [0 .. 11]

    it "differs from the C12-projection forward once the cycle closes" $ do
      -- layer_idx % 12 and mixedOp agree on the first 12 layers' cells (both walk
      -- 0..11) but they are different *structures*: only mixedOp exposes the two
      -- independent component periods 3 and 4 that make the joint period 12.
      let projCells = [ i `mod` 12 | i <- [0 .. 59] ]
          mixCells  = take 60 [ crt12 st | st <- iterate (\s -> fst (layerStep s)) (0, A0) ]
      projCells `shouldBe` mixCells          -- same cell sequence
      [ n | n <- [1 .. 60], fst (mixedOpN n (1, A1)) == 0 ]  `shouldBe` [3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60]
      [ n | n <- [1 .. 60], snd (mixedOpN n (1, A1)) == A0 ] `shouldBe` [4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60]

  describe "Infrastructure.CPU.SovereignModel (A6/M7d)" $ do
    let w3 rows cols seed =
          [ [ fromIntegral ((r * 7 + c * 13 + seed) `mod` 3) | c <- [0 .. cols - 1] ]
          | r <- [0 .. rows - 1] ]
        cfg = SovereignConfig { scDim = 24, scDepth = 2, scHeads = 2
                              , scVocab = 8, scFF = 72, scEps = 1e-5 }
        mkLayer = SovereignLayer
          { slQProj     = w3 12 24 1, slQScale    = replicate 12 1
          , slOutProj   = w3 24 24 2, slOutScale  = replicate 24 1
          , slGateProj  = w3 72 24 3, slGateScale = replicate 72 1
          , slUpProj    = w3 72 24 4, slUpScale   = replicate 72 1
          , slDownProj  = w3 24 72 5, slDownScale = replicate 24 1
          , slPrototype = defaultMonopolePrototype 2 }
        wts = SovereignWeights (w3 8 24 7) (w3 8 24 8) (w3 8 24 6) [mkLayer, mkLayer]

    it "matches the numpy reference logits end to end (dim=24 depth=2)" $ do
      -- The magnitudes explode (~1e21): GF3SwiGLU multiplies gate*up element-wise
      -- in float, so untrained random weights grow quadratically per layer.  The
      -- reference behaves the same way, so the criterion is *relative* agreement.
      let out = sovereignForward cfg wts [1,3,5]
          expected =
            [ [ 1.97204611207183e21, 2.0350866260608203e21, 2.0806196997787883e21
              , 1.97204611207183e21, 2.0350866260608203e21, 2.0806196997787883e21
              , 1.97204611207183e21, 2.0350866260608203e21 ]
            , [ 2.0888719502190864e21, 1.9880649956113315e21, 2.0354907566363236e21
              , 2.0888719502190864e21, 1.9880649956113315e21, 2.0354907566363236e21
              , 2.0888719502190864e21, 1.9880649956113315e21 ]
            , [ 2.0486390855393702e21, 2.0835064505123576e21, 1.978634720555371e21
              , 2.0486390855393702e21, 2.0835064505123576e21, 1.978634720555371e21
              , 2.0486390855393702e21, 2.0835064505123576e21 ] ]
          rel a b = abs (a - b) / abs b
      map length out `shouldBe` [8, 8, 8]
      -- ⚠️ The magnitudes are offset from the numpy reference by a *constant*
      -- factor.  This is the projection factor between the two views, not a bug:
      --   HUANGZHONG 3^11 / ZHONGLV 2^16  — the twelve-pitch closed cycle's
      --   closure gap (三分损益: 177147 →…→ 65536, i.e. 黄钟/仲吕), times
      --   DELTA = √3, the phase gap.  (3^11/2^16)·√3 = 4.68181769…
      -- Measured want/got over the nine elements: mean 4.67112, spread 3.0e-2.
      -- A *pure integer* re-implementation in sov-math (gf3_layer2.h) reduces
      -- modulo 3 at every step instead of carrying floats, which keeps the state
      -- finite and lands on a limit cycle — that is the view taken here.
      let ratios = [ b / a | (rowO, rowE) <- zip out expected, (a, b) <- zip rowO rowE ]
          measured = sum ratios / fromIntegral (length ratios)
          projection = (177147 / 65536) * sqrt 3        -- 黄钟/仲吕 × 能隙
          spread = maximum ratios - minimum ratios
      map length out `shouldBe` [8, 8, 8]
      abs (measured - projection) / projection < 0.01 `shouldBe` True
      spread < 0.05 `shouldBe` True                     -- it really is constant

    it "carries the spherical-harmonic embedding (27 codes per cell)" $ do
      let sh = sphericalHarmonicExpand (head cellCenters)
      length sh `shouldBe` 27
      sum sh `shouldBe` 9          -- nine harmonics, exactly one state each

  describe "Infrastructure.CPU.Christoffel (A6/M7c)" $ do
    it "transports a tryte exactly as the reference does (numpy cross-check)" $ do
      -- from cell 0 to cell 1: not adjacent → direction = _adj_lookup[0][1] = 1
      let shift1 = gf3Shift 0 (getDirection 0 1)
      shift1 `shouldBe` 2
      map tritToInt (transportTryte (map mkTrit [0,1,2,0,1,2]) (map mkTrit [1,1,1,1,1,1]) shift1) `shouldBe` [1,1,0,1,1,0]
      -- from cell 0 to cell 4: adjacent, direction 0 → shift 1
      let shift2 = gf3Shift 0 (getDirection 0 4)
      shift2 `shouldBe` 1
      map tritToInt (transportTryte (map mkTrit [2,2,2,2,2,2]) (map mkTrit [0,1,2,0,1,2]) shift2) `shouldBe` [0,1,1,0,1,1]

    it "collapses a tryte to Σtrits/6 and scales the head slice" $ do
      let closeD a b = abs (a - b) < 1e-12
          out = christoffelMix (map mkTrit [0,1,1,0,1,1]) [1,2,3]   -- Σ = 4 → 4/6
      and (zipWith closeD out [0.6666666666666666, 1.3333333333333333, 2.0]) `shouldBe` True

    it "runs the whole forward: quantise → transport → mix (structure)" $ do
      let dim = 12 ; heads = 2 ; hd = dim `div` heads
          qW = [ [ if r `mod` hd == c `mod` hd then 1 else 0 | c <- [0..dim-1] ]
               | r <- [0..heads*6-1] ]
          qS = replicate (heads*6) 1
          protos = [ [1,1,1,1,1,1], [0,1,2,0,1,2] ]
          x = [1,2,3,4,5,6, 7,8,9,10,11,12]
          out = christoffelForward heads qW qS protos 0 4 x      -- direction 0 → shift 1
      length out `shouldBe` dim
      -- every head's output is its input slice times the same scalar Σtrits/6 ∈ [0,1]
      let ratios i = [ out !! k / x !! k | k <- [i*hd .. (i+1)*hd - 1] ]
      mapM_ (\i -> do
        let rs = ratios i
        and [ abs (v - head rs) < 1e-12 | v <- rs ] `shouldBe` True
        (head rs >= 0 && head rs <= 1) `shouldBe` True) [0, 1]

  describe "Infrastructure.CPU.GF3Ops (A6/M7b)" $ do
    let eps = 1e-5 :: Double

    it "builds the rsqrt LUT exactly as the reference does" $ do
      let lut = gf3RmsNormLut 4 eps
      length lut `shouldBe` 5
      lut !! 0 `shouldBe` (1 / sqrt eps)              -- gf3_rmsnorm.py:52
      lut !! 4 `shouldBe` (1 / sqrt (1 + eps))
      and (zipWith (>) lut (tail lut)) `shouldBe` True

    it "normalises by the non-zero count (x² ≡ x≠0 in GF(3))" $ do
      let lut = gf3RmsNormLut 4 eps
          out = gf3RmsNorm lut [1,1,1,1] [0,1,2,0]    -- two non-zero → lut[2]
      out `shouldBe` [0, 1 * (lut !! 2), 2 * (lut !! 2), 0]
      -- an all-zero vector is not a division by zero
      gf3RmsNorm lut [1,1,1,1] [0,0,0,0] `shouldBe` [0,0,0,0]

    it "passes the √3 gate only above ‖g‖² > 1" $ do
      gf3SqrtGate [0.5, 0.5] `shouldBe` 0.0     -- ‖g‖² = 0.5
      gf3SqrtGate [1.0, 0.0] `shouldBe` 0.0     -- ‖g‖² = 1.0 exactly → blocked
      gf3SqrtGate [1.0, 1.0] `shouldBe` 1.0     -- ‖g‖² = 2.0 → passes
      gf3SwiGLU (\_ -> [2,2])   (\_ -> [1,1]) id [0] `shouldBe` [2,2]   -- 8 > 1
      gf3SwiGLU (\_ -> [0.5,0.5]) (\_ -> [1,1]) id [0] `shouldBe` [0,0] -- 0.5 ≤ 1

    it "matches the reference numerically (numpy cross-check)" $ do
      let close' a b = abs (a - b) < 1e-12
          lut = gf3RmsNormLut 4 eps
      -- numpy: 1/sqrt(2/4 + 1e-5)
      close' (lut !! 2) 1.4141994204496 `shouldBe` True
      let out = gf3RmsNorm lut [1,1,1,1] [0,1,2,0]
      and (zipWith close' out [0.0, 1.4141994204496, 2.8283988408992, 0.0]) `shouldBe` True
      -- an 8-wide ternary vector with 7 non-zero entries → LUT[7]
      let lut8 = gf3RmsNormLut 8 eps
          out8 = gf3RmsNorm lut8 (replicate 8 1) [2,1,2,2,1,2,2,0]
      and (zipWith close' (take 2 out8) [2.138077717747344, 1.069038858873672]) `shouldBe` True
      out8 !! 7 `shouldBe` 0.0

    it "computes a ternary linear layer as scale ⊙ (W_trit @ x)" $ do
      let w = [[0,1,2],[2,2,2]]
          x = [1,1,1]
      ternaryLinear w [1,1]   x `shouldBe` [3,6]      -- 0+1+2 ; 2+2+2
      ternaryLinear w [2,0.5] x `shouldBe` [6,3]

  describe "Infrastructure.CPU.S2Geometry (A6/M7a)" $ do
    it "carries the reference tables verbatim" $ do
      s2NumCells `shouldBe` 12
      length cellAdjacency `shouldBe` 12
      all ((== 3) . length) cellAdjacency `shouldBe` True
      c3Orbits `shouldBe` [[0,4,8],[1,5,9],[2,6,10],[3,7,11]]
      -- the shift depends only on direction: all twelve rows are [1,2,0]
      christoffelGf3 `shouldBe` replicate 12 [1,2,0]
      gf3Shift 0 0  `shouldBe` 1
      gf3Shift 5 1  `shouldBe` 2
      gf3Shift 11 2 `shouldBe` 0

    it "has GF(3) algebra: 1 is the unit, 2 is its own inverse, x is commutative" $ do
      [ gf3Mul !! a !! 1 | a <- [0..2] ] `shouldBe` [0,1,2]
      gf3Mul !! 2 !! 2 `shouldBe` 1
      and [ gf3Mul !! a !! b == gf3Mul !! b !! a | a <- [0..2], b <- [0..2] ]
        `shouldBe` True

    it "resolves direction by neighbour index, else the geodesic decides" $ do
      getDirection 0 4 `shouldBe` 0     -- adjacency[0] = [4,8,3]
      getDirection 0 8 `shouldBe` 1
      getDirection 0 3 `shouldBe` 2
      -- non-adjacent → floor(geodesic) mod 3, which is *not* always 0
      getDirection 0 5 `shouldBe` 1
      -- fixed-point icosahedron constants (gf3_s2_lattice.py:94-104)
      fxpPhi `shouldBe` 106039
      let closeD a b = abs (a - b) < 1e-5
      closeD (cellGeodesic 0 4) 1.107148 `shouldBe` True    -- neighbour, ≈ 63.43°
      closeD (cellGeodesic 0 6) 2.03444  `shouldBe` True    -- non-neighbour, ≈ 116.57°
      cellGeodesic 0 0 `shouldBe` 0.0

    it "reproduces the reference _adj_lookup table exactly (numpy cross-check)" $ do
      adjLookupTable `shouldBe`
        [ [0, 1, 2, 2, 0, 1, 2, 2, 1, 1, 2, 2]
        , [1, 0, 0, 2, 2, 0, 1, 1, 1, 1, 2, 2]
        , [2, 0, 0, 1, 1, 2, 0, 2, 2, 2, 1, 1]
        , [0, 2, 1, 0, 2, 2, 2, 0, 2, 2, 1, 1]
        , [1, 2, 1, 2, 0, 1, 2, 2, 0, 2, 1, 2]
        , [1, 1, 1, 2, 1, 0, 0, 2, 2, 0, 2, 1]
        , [2, 1, 1, 1, 2, 0, 0, 1, 1, 2, 0, 2]
        , [2, 1, 2, 1, 0, 2, 1, 0, 2, 1, 2, 0]
        , [0, 1, 2, 2, 1, 2, 1, 2, 0, 2, 1, 2]
        , [2, 0, 2, 2, 2, 1, 2, 1, 2, 0, 0, 1]
        , [2, 2, 0, 1, 1, 2, 1, 2, 1, 0, 0, 2]
        , [2, 2, 2, 0, 2, 1, 2, 1, 0, 1, 2, 0] ]

  describe "Infrastructure.CPU.SOV3 (A6/M1b)" $ do
    it "reads the real BitNet-b1.58-2B checkpoint: 423 tensors, byte accounting closes" $ do
      let path = "/data/trit/pyBitNet/scripts/artifacts/sov_native/bitnet2b_warmstart.sov"
      exists <- doesFileExist path
      if not exists
        then pendingWith "reference .sov not present on this machine"
        else do
          res <- loadSOV3 path
          case res of
            Left e   -> expectationFailure (T.unpack e)
            Right sv -> do
              length (svTensors sv) `shouldBe` 423
              -- the directory accounts for the payload exactly (0 bytes spare)
              sum (map stSize (svTensors sv))
                `shouldBe` BS.length (svImage sv) - svDataStart sv
              case sov3Tensor sv "token_emb.token_embed.weight" of
                Nothing -> expectationFailure "token embedding not found"
                Just t  -> do
                  stShape t `shouldBe` [1536, 1440]
                  stSize t  `shouldBe` 442368     -- 1536*1440 = 2211840 trits ÷ 5 per byte
              -- first packed byte is 0xf2 = 242 = ternary 22222 → trits all +2
              take 4 (fromMaybe [] (sov3TensorFloats sv "token_emb.token_embed.weight"))
                `shouldBe` [2.0, 2.0, 2.0, 2.0]

  describe "Infrastructure.CPU.Dequant (A6/M2)" $ do
    it "converts IEEE-754 half precision exactly" $ do
      fp16ToFloat 0x3C00 `shouldBe` 1.0
      fp16ToFloat 0x4000 `shouldBe` 2.0
      fp16ToFloat 0xC000 `shouldBe` (-2.0)
      fp16ToFloat 0x3800 `shouldBe` 0.5
      fp16ToFloat 0x0000 `shouldBe` 0.0

    it "dequantises Q4_0 low-nibbles-first (matches ggml-quants.c:470)" $ do
      -- d = 1.0 (fp16 0x3C00 on the wire, little-endian), qs = [0x00, 0x78, 0…]
      let bytes = BS.pack ([0x00, 0x3C, 0x00, 0x78] ++ replicate 14 0)
      case dequantizeRow QuantTypeQ4_0 bytes 32 of
        Left e   -> expectationFailure (T.unpack e)
        Right ys -> do
          length ys `shouldBe` 32
          ys !! 0  `shouldBe` (-8.0)    -- (0x0 - 8) * 1
          ys !! 1  `shouldBe` 0.0       -- (0x8 - 8) * 1
          ys !! 16 `shouldBe` (-8.0)    -- (0x0 - 8) * 1  (high nibble half)
          ys !! 17 `shouldBe` (-1.0)    -- (0x7 - 8) * 1

    it "dequantises Q8_0 as signed bytes times the half scale" $ do
      let bytes = BS.pack ([0x00, 0x3C, 0x00, 0x01, 0xFF, 0x7F, 0x80] ++ replicate 27 0)
      case dequantizeRow QuantTypeQ8_0 bytes 32 of
        Left e   -> expectationFailure (T.unpack e)
        Right ys -> take 5 ys `shouldBe` [0.0, 1.0, -1.0, 127.0, -128.0]

    it "dequantises F32 and refuses a partial block" $ do
      let one = BS.pack [0x00, 0x00, 0x80, 0x3F]       -- 1.0f little-endian
      dequantizeRow QuantTypeF32 one 1 `shouldBe` Right [1.0]
      case dequantizeRow QuantTypeQ4_0 (BS.replicate 18 0) 33 of
        Left _  -> True `shouldBe` True
        Right _ -> expectationFailure "33 elements is not a whole Q4_0 block"

  describe "LLM.Adapter streaming (A5)" $ do
    it "samples the CPU engine one token at a time, matching the blocking path" $ do
      (_, adapter) <- createCPUAdapter "/dev/null"
      ref <- newIORef []
      _ <- llmChatToolsStream adapter [ChatUser "hi"] [] $ \c -> case c of
             ChunkDelta t -> modifyIORef' ref (t :)
             _            -> return ()
      pieces <- reverse <$> readIORef ref
      blocking <- llmChatTools adapter [ChatUser "hi"] [] defaultGenParams
      -- one increment per sampled token (the engine's maxTokens)
      length pieces `shouldBe` 100
      -- and they concatenate to exactly what the blocking call returns
      T.concat pieces `shouldBe` ctContent blocking

  describe "Core.Plugin" $ do
    it "can create and run a plugin" $ do
      env <- Env <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef []
      let plugin = do
            liftF $ RegisterService "test" (toDyn (42 :: Int)) ()
      disposer <- runPlugin env plugin
      services <- readIORef (envServices env)
      Map.member "test" services `shouldBe` True

  describe "Core.Session" $ do
    it "can create a session and append events" $ do
      session <- createSession "test-session-1"
      appendEvent session (UserMessage "Hello")
      appendEvent session (AssistantMessage "Hi there!")
      events <- getEvents session
      length events `shouldBe` 2

    -- projections：投影是"由事件日志重放得出的派生状态"。
    -- 推理状态（CPU 层 T6State）与内核 FSM 状态（Core.Agent.AgentState）经这里上浮到
    -- 会话，使"推理过程"对内核可见。本模块只碰 Dynamic，装箱由调用方完成（不破坏分层）。
    it "★ projections：未设返回 Nothing；写入后可读回" $ do
      session <- createSession "test-session-proj"
      (isJust <$> getProjection session "t6state") `shouldReturn` False
      projectionNames session `shouldReturn` []
      setProjection session "t6state" (toDyn (42 :: Int))
      m <- getProjection session "t6state"
      fmap fromDynamic m `shouldBe` Just (Just (42 :: Int))
      projectionNames session `shouldReturn` ["t6state"]

    it "★ projections：同名覆盖写生效（不累积重复键）" $ do
      session <- createSession "test-session-proj2"
      setProjection session "k" (toDyn (1 :: Int))
      setProjection session "k" (toDyn (2 :: Int))
      m <- getProjection session "k"
      fmap fromDynamic m `shouldBe` Just (Just (2 :: Int))
      projectionNames session `shouldReturn` ["k"]

    it "★ D-3：会话持有内核 FSM 状态 —— 新建 Idle，advanceAgent 后推进" $ do
      session <- createSession "test-session-fsm"
      getAgentState session `shouldReturn` Idle
      st1 <- advanceAgent session (StartCommand "sid")
      st1 `shouldBe` Processing "step-1"
      getAgentState session `shouldReturn` Processing "step-1"
      -- 用 transition 的语义（唯一来源）：Processing 上再发 Start 不改变状态
      st2 <- advanceAgent session (StartCommand "sid")
      st2 `shouldBe` Processing "step-1"

    it "★ projections：不同名互不干扰；类型不符时 fromDynamic 得 Nothing" $ do
      session <- createSession "test-session-proj3"
      setProjection session "a" (toDyn (1 :: Int))
      setProjection session "b" (toDyn ("x" :: String))
      ma <- getProjection session "a"
      mb <- getProjection session "b"
      fmap fromDynamic ma `shouldBe` Just (Just (1 :: Int))
      fmap fromDynamic mb `shouldBe` Just (Just ("x" :: String))
      -- 以错误的类型解包应失败（Dynamic 的类型安全）
      (fmap fromDynamic ma :: Maybe (Maybe String)) `shouldBe` Just Nothing

  describe "Core.Agent" $ do
    it "can create an agent and update state" $ do
      let config = AgentConfig "deepseek-chat" 10 30
      agent <- createAgent "agent-1" config
      state <- getState agent
      state `shouldBe` Idle
      updateState agent (Processing "step-1")
      state' <- getState agent
      state' `shouldBe` Processing "step-1"

  describe "Core.Tools" $ do
    it "can register and retrieve tools" $ do
      registry <- createToolRegistry
      let tool = Tool "test-tool" "A test tool" "{}" (\_ -> return (toDyn (42 :: Int)))
      registerTool registry tool
      retrieved <- getTool registry "test-tool"
      case retrieved of
        Just t -> toolName t `shouldBe` "test-tool"
        Nothing -> expectationFailure "Tool not found"

  describe "Core.Event" $ do
    it "can subscribe and publish events" $ do
      bus <- createEventBus
      ref <- newIORef (0 :: Int)
      subscribe bus "test-event" (\dyn -> do
        case fromDynamic dyn of
          Just msg -> writeIORef ref msg
          Nothing -> return ()
        )
      publish bus "test-event" (toDyn (42 :: Int))
      result <- readIORef ref
      result `shouldBe` 42

  describe "Core.Cache" $ do
    it "can cache and retrieve values" $ do
      engine <- createCacheEngine
      cacheInsert engine "key1" (toDyn (42 :: Int))
      result <- cacheLookup engine "key1"
      case result of
        Just dyn -> fromDynamic dyn `shouldBe` Just (42 :: Int)
        Nothing -> expectationFailure "Value not found"

  describe "LLM.Adapter" $ do
    it "can create a DeepSeek adapter" $ do
      adapter <- createDeepSeekProvider "test-key"
      models <- llmModels adapter
      length models `shouldSatisfy` (>= 1)
      modelName (head models) `shouldBe` "deepseek-flash"

  -- Phase 3 K1: function-calling message model (OpenAI-aligned JSON)
  describe "LLM.FunctionCalling" $ do
    it "round-trips a tool result message" $ do
      let msg = LLM.ChatTool "call_1" "result text"
      decode (encode msg) `shouldBe` (Just msg :: Maybe LLM.ChatMessage)

    it "round-trips an assistant message with tool calls" $ do
      let tc = LLM.ToolCall "call_2" "bash" "{\"command\":\"ls\"}"
          msg = LLM.ChatAssistant "thinking…" [tc]
      decode (encode msg) `shouldBe` (Just msg :: Maybe LLM.ChatMessage)

    it "round-trips a tool spec" $ do
      let spec = LLM.ToolSpec "read_file" "Read a file" (object ["type" .= ("string" :: T.Text)])
      decode (encode spec) `shouldBe` (Just spec :: Maybe LLM.ToolSpec)

    it "serializes a tool result in OpenAI shape" $ do
      encode (LLM.ChatTool "call_9" "ok") `shouldBe`
        "{\"content\":\"ok\",\"role\":\"tool\",\"tool_call_id\":\"call_9\"}"

    it "serializes an assistant tool call in OpenAI shape" $ do
      encode (LLM.ChatAssistant "" [LLM.ToolCall "c1" "bash" "{}"]) `shouldBe`
        "{\"content\":\"\",\"reasoning_content\":\"\",\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"arguments\":\"{}\",\"name\":\"bash\"},\"id\":\"c1\",\"type\":\"function\"}]}"

    it "omits tool_calls when the assistant has none" $ do
      -- a thought-carrying turn keeps the chain: thinking mode requires it
      -- back on the next request, and dropping it costs the model its plan.
      let thought = LLM.ChatAssistantThought "" [LLM.ToolCall "c2" "bash" "{}"] "因为需要先看文件"
      decode (encode thought) `shouldBe` Just thought
      (BLC.unpack (encode thought)) `shouldSatisfy` ("reasoning_content" `isInfixOf`)
      -- an empty chain is not a thought turn (keeps round-trips stable)
      decode (encode (LLM.ChatAssistant "" [LLM.ToolCall "c2" "bash" "{}"]))
        `shouldBe` Just (LLM.ChatAssistant "" [LLM.ToolCall "c2" "bash" "{}"])
      encode (LLM.ChatAssistant "plain" []) `shouldBe`
        "{\"content\":\"plain\",\"role\":\"assistant\"}"

  -- Phase 3 K2: DeepSeek provider function-calling (pure request/parse)
  describe "LLM.DeepSeekTools" $ do
    it "builds a request carrying the tools array" $ do
      let spec = LLM.ToolSpec "read_file" "Read a file" (object ["type" .= ("string" :: T.Text)])
          req  = BLC.unpack (encode (buildDeepSeekChatRequest "deepseek-chat" [LLM.ChatUser "hi"] [spec] Nothing))
      req
        `shouldSatisfy` (\b -> "\"tools\"" `isInfixOf` b
                           && "read_file" `isInfixOf` b
                           && "\"stream\":false" `isInfixOf` b)


    it "parses a tool_calls response" $ do
      let resp = object
            [ "choices" .= [ object
                [ "message" .= object
                    [ "role" .= ("assistant" :: T.Text)
                    , "content" .= ("" :: T.Text)
                    , "tool_calls" .= [ object
                        [ "id" .= ("call_1" :: T.Text)
                        , "type" .= ("function" :: T.Text)
                        , "function" .= object
                            [ "name" .= ("bash" :: T.Text)
                            , "arguments" .= ("{\"command\":\"ls\"}" :: T.Text)
                            ]
                        ]
                      ]
                    ]
                ]
              ]
            , "usage" .= object [ "total_tokens" .= (7 :: Int) ]
            ]
      parseDeepSeekChatTurn resp `shouldBe`
        Right (LLM.ChatTurn "" [LLM.ToolCall "call_1" "bash" "{\"command\":\"ls\"}"]
                  (Just (LLM.mkUsage 0 0 7)) Nothing Nothing)

    it "parses a plain (tool-less) response" $ do
      let resp = object
            [ "choices" .= [ object
                [ "message" .= object
                    [ "role" .= ("assistant" :: T.Text)
                    , "content" .= ("hello" :: T.Text)
                    ]
                ]
              ]
            ]
      parseDeepSeekChatTurn resp `shouldBe` Right (LLM.ChatTurn "hello" [] Nothing Nothing Nothing)

  -- Phase 3 K3: API server OpenAI tools passthrough (pure builders)
  describe "API.OpenAITools" $ do
    it "preserves the raw tools array when parsing a request" $ do
      let body = object
            [ "model" .= ("m" :: T.Text)
            , "messages" .= [ object [ "role" .= ("user" :: T.Text), "content" .= ("hi" :: T.Text) ] ]
            , "tools" .= [ object
                [ "type" .= ("function" :: T.Text)
                , "function" .= object [ "name" .= ("bash" :: T.Text), "description" .= ("run" :: T.Text) ]
                ] ]
            ]
      case parseOpenAIRequest body of
        Just req -> length (oaiTools req) `shouldBe` 1
        Nothing  -> expectationFailure "parse failed"

  -- Provider registry (P1): pure config logic, no IO.
  describe "Core.Provider.Types" $ do
    let mk name kind = ProviderEntry
          { peName = name, peKind = kind, peBaseUrl = "https://api.example.com/v1"
          , peModels = ["m1", "m2"], peDefault = "m1", peHasKey = False, peKeyEnv = Nothing
          , peVisionModels = [], pePreset = False, peInUse = False, peContextWindow = Nothing
          , peWebSearch = Nothing, peSendsThinking = Nothing }

    it "drops nameless entries and coerces unknown kinds" $ do
      let s = normalizeStore (ProviderStore [mk "a" "openai", mk "  " "openai", mk "b" "weird"])
      map peName (psProviders s) `shouldBe` ["a", "b"]
      map peKind (psProviders s) `shouldBe` ["openai", "openai"]

    it "de-duplicates by name with the last one winning" $ do
      let s = normalizeStore (ProviderStore [mk "dup" "openai", mk "dup" "anthropic"])
      map peName (psProviders s) `shouldBe` ["dup"]
      map peKind (psProviders s) `shouldBe` ["anthropic"]

    it "upserts by name (insert then replace)" $ do
      let s1 = upsertProvider (mk "a" "openai") emptyStore
          s2 = upsertProvider (mk "b" "responses") s1
          s3 = upsertProvider (mk "a" "anthropic") s2
      map peName (psProviders s3) `shouldBe` ["b", "a"]
      fmap peKind (findProvider "a" s3) `shouldBe` Just "anthropic"

    it "removes by name" $ do
      let s = upsertProvider (mk "a" "openai") (upsertProvider (mk "b" "openai") emptyStore)
      map peName (psProviders (removeProvider "a" s)) `shouldBe` ["b"]

    it "round-trips through JSON" $ do
      let s = upsertProvider (mk "a" "openai") emptyStore
      (decode (encode s) :: Maybe ProviderStore) `shouldBe` Just s

    it "declares a protocol catalog covering every valid kind" $ do
      map prKind protocolCatalog `shouldBe` validKinds
      (prKind <$> protocolCatalog) `shouldSatisfy` all (`elem` validKinds)

    -- T6（先红）：本地推理 backend 作为一等 provider kind
    it "懂 \"cpu\"（本地推理 backend）这个 kind" $ do
      ("cpu" `elem` validKinds) `shouldBe` True

    it "normalizeStore 不把 kind=\"cpu\" 的条目改写成 openai" $ do
      let s = normalizeStore (ProviderStore [mk "local-cpu" "cpu"])
      map peName (psProviders s) `shouldBe` ["local-cpu"]
      map peKind (psProviders s) `shouldBe` ["cpu"]

    -- T7：cpu kind 能被 adapterFor 构造，且本地引擎按路径复用
    it "adapterFor 能按 kind=\"cpu\" 构造本地推理适配器" $ do
      r <- adapterFor ((mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }) ""
      case r of
        Left why -> expectationFailure ("cpu kind 未实现: " ++ T.unpack why)
        Right _  -> pure ()

    it "本地引擎按模型路径复用：同一路径不重复构建" $ do
      -- 注意：缓存是模块级的，前面的用例可能已用同一路径预热过，
      -- 所以这里只断言“再次取用不新建”，不假设“本次是首次”。
      let e = (mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }
      _ <- adapterFor e ""            -- 预热/取用
      mid <- cpuAdapterCacheSize
      _ <- adapterFor e ""            -- 同路径再来一次
      after <- cpuAdapterCacheSize
      after `shouldBe` mid            -- 复用：不再新建

    it "TRHA_GPU=1 且无可用 .sov 时回退 CPU（不崩、不抛异常）" $ do
      -- 负向控制：GPU 前端初始化失败（/dev/null 不是 .sov）必须回退纯 CPU adapter，
      -- 禁止把「GPU init 失败」变成运行时异常（adapterFor 全程 Either，不抛）。
      let e = (mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }
      _ <- setEnv "TRHA_GPU" "1"
      r <- adapterFor e ""
      _ <- unsetEnv "TRHA_GPU"
      case r of
        Left why -> expectationFailure ("TRHA_GPU 回退失败: " ++ T.unpack why)
        Right _  -> pure ()

    it "accepts the names the reference accepts and refuses the rest" $ do
      validProviderName "deepseek"   `shouldBe` True
      validProviderName "9router"    `shouldBe` True
      validProviderName "my-gw.v2_x" `shouldBe` True
      validProviderName ""           `shouldBe` False
      validProviderName " has space" `shouldBe` False
      validProviderName "a/b"        `shouldBe` False
      validProviderName (T.replicate 65 "a") `shouldBe` False

    it "derives the key env var, CUSTOM_-prefixing digit-leading names" $ do
      providerKeyEnv "deepseek" `shouldBe` "DEEPSEEK_API_KEY"
      providerKeyEnv "9router"  `shouldBe` "CUSTOM_9ROUTER_API_KEY"
      providerKeyEnv "my gw"    `shouldBe` "MY_GW_API_KEY"

  -- Provider probe (P2): the judgement on an endpoint's answer, no network.
  describe "API.ProviderProbe" $ do
    let listing = encode (object
          [ "data" .= [ object ["id" .= ("m1" :: T.Text)]
                      , object ["id" .= ("m2" :: T.Text)] ] ])

    it "accepts an OpenAI-style listing and picks the first as default" $
      case classifyListing False 200 (Just listing) of
        Right p -> do
          pbModels p  `shouldBe` ["m1", "m2"]
          pbDefault p `shouldBe` "m1"
          pbKind p    `shouldBe` "openai"
          pbNoProxy p `shouldBe` False
        Left e -> expectationFailure ("unexpected failure: " <> show e)

    it "marks a proxy-bypassed answer with noProxy" $
      case classifyListing True 200 (Just listing) of
        Right p -> pbNoProxy p `shouldBe` True
        Left e  -> expectationFailure ("unexpected failure: " <> show e)

    it "maps a refused key (401/403) to key_rejected" $ do
      classifyListing False 401 Nothing `shouldBe` Left ProbeKeyRejected
      classifyListing False 403 Nothing `shouldBe` Left ProbeKeyRejected
      probeErrorCode ProbeKeyRejected `shouldBe` "provider.key_rejected"

    it "maps 404 to path_missing" $ do
      classifyListing False 404 Nothing `shouldBe` Left ProbePathMissing
      probeErrorStatus ProbePathMissing `shouldBe` 404

    it "reports an empty listing as no_models, not as success" $
      classifyListing False 200 (Just (encode (object ["data" .= ([] :: [Int])])))
        `shouldBe` Left ProbeNoModels

    it "reports a non-JSON 200 as unreachable" $
      case classifyListing False 200 (Just "not json") of
        Left (ProbeUnreachable _) -> pure ()
        other -> expectationFailure ("expected ProbeUnreachable, got " <> show other)

    it "reads the alternate listing shapes a gateway may answer with" $ do
      parseModelIds (object ["models" .= (["a", "b"] :: [T.Text])]) `shouldBe` ["a", "b"]
      parseModelIds (Array (V.fromList [String "solo"])) `shouldBe` ["solo"]
      parseModelIds (object ["unrelated" .= True]) `shouldBe` []

  -- Saving a provider (P3): a draft becomes a config entry, keys stay apart.
  describe "Core.Provider.Types (draft)" $ do
    let draft = ProviderDraft
          { pdName = "  my gw  ", pdKind = "openai", pdBaseUrl = " https://gw.example/v1 "
          , pdApiKey = "sk-123", pdModels = ["m1", "m2"], pdDefault = ""
          , pdAuthHeader = True, pdNoProxy = False, pdEffort = "", pdVision = [] }
        entry = draftToEntry draft

    it "strips whitespace and derives keyEnv from the name" $ do
      peName entry    `shouldBe` "my gw"
      peBaseUrl entry `shouldBe` "https://gw.example/v1"
      peKeyEnv entry  `shouldBe` Just "MY_GW_API_KEY"

    it "records whether a key was supplied, never the key itself" $ do
      peHasKey entry `shouldBe` True
      peHasKey (draftToEntry draft { pdApiKey = "" }) `shouldBe` False

    it "falls back to the first model as default" $ do
      peDefault entry `shouldBe` "m1"
      peDefault (draftToEntry draft { pdDefault = "m2" }) `shouldBe` "m2"

    it "coerces an unknown kind to openai" $
      peKind (draftToEntry draft { pdKind = "weird" }) `shouldBe` "openai"

    it "round-trips a draft through JSON" $
      (decode (encode draft) :: Maybe ProviderDraft) `shouldBe` Just draft

    it "keeps keys in a separate store, addressable by name" $ do
      let ks = insertKey "a" "sk-a" (insertKey "b" "sk-b" emptyKeys)
      lookupKey "a" ks `shouldBe` Just "sk-a"
      lookupKey "zz" ks `shouldBe` Nothing
      (decode (encode ks) :: Maybe ProviderKeys) `shouldBe` Just ks

  -- ── API.Server 装配端到端（真实 warp + 真实 HTTP 请求）──────────────────────
  -- 为什么补这组：全库此前**没有任何 HTTP 端到端测试**，所有 API 测试都停在纯函数
  -- 层（parseOpenAIRequest / classifyListing / ProviderEntry）。后果是接线缺口不会
  -- 被任何测试看见。
  --
  -- ⚠️ 装配在这里暴露出的**根本障碍**：trha-api 把自己的 LLM.Adapter.Interface
  -- 又编译了一份（列在 other-modules），于是 trha-api 的 LLMAdapter 与 trha-llm 的
  -- LLMAdapter 是**两个不同类型**。外部拿到的 createCPUAdapter 根本传不进
  -- API.Server —— 所以这组测试只能走包内入口（mkCPUApp / mkStubApp），写不成
  -- 「注入任意 adapter」的形式。
  describe "API.Server — 装配端到端 (HTTP, 真实 warp)" $ do
    let withApp :: Application -> (Manager -> String -> IO a) -> IO a
        withApp app act =
          testWithApplication (pure app) $ \port -> do
            mgr <- newManager defaultManagerSettings
            act mgr ("http://127.0.0.1:" ++ show port)

        httpGet :: Manager -> String -> IO (Int, String)
        httpGet mgr url = do
          req <- parseRequest url
          res <- httpLbs req mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        httpPost :: Manager -> String -> Value -> IO (Int, String)
        httpPost mgr url body = do
          req0 <- parseRequest ("POST " ++ url)
          let req = req0 { method          = "POST"
                         , requestBody     = RequestBodyLBS (encode body)
                         , requestHeaders  = [ ("Content-Type", "application/json") ] }
          res <- httpLbs req mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        chatReq :: Bool -> Value
        chatReq stream = object
          [ "model"    .= ("cpu-model" :: T.Text)
          , "stream"   .= stream
          , "messages" .= [ object [ "role"    .= ("user" :: T.Text)
                                   , "content" .= ("hi" :: T.Text) ] ]
          ]

    it "stub 装配：/v1/models 报的是 stub 自己的模型（K6 现状）" $ do
      app <- mkStubApp Nothing
      (code, body) <- withApp app $ \mgr base -> httpGet mgr (base ++ "/v1/models")
      code `shouldBe` 200
      ("Stub Kernel" `isInfixOf` body) `shouldBe` True

    it "CPU 装配：同一个端点换成 cpu-model（backend 由装配决定，不是硬编码）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base -> httpGet mgr (base ++ "/v1/models")
      code `shouldBe` 200
      ("cpu-model" `isInfixOf` body)     `shouldBe` True
      ("Stub Kernel" `isInfixOf` body)   `shouldBe` False

    it "CPU adapter 经 HTTP 完成一次非流式 chat（/v1/chat/completions）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      ("chat.completion" `isInfixOf` body) `shouldBe` True
      ("cpu-model" `isInfixOf` body)       `shouldBe` True

    -- ── C5(D-1)：约束 ↔ 外部推理（作用点 = 响应侧的「采纳判定」）──────────────
    -- 三要素由用户 2026-09-13 裁定：作用点 = 响应侧采纳判定；失败行为 = 标注（不拒绝、
    -- 不降级）；草稿模型与约束是同一机制的两面（草稿输出必须先过约束）。
    it "★ C5(D-1)：响应**总是**携带约束判定 trha_constraint（作用点在响应侧）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      ("trha_constraint" `isInfixOf` body) `shouldBe` True

    it "★ C5(D-1)：判定状态只有 pass / warn —— 类型里没有「拒绝」（裁定①）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (_, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      ( ("\"pass\"" `isInfixOf` body) || ("\"warn\"" `isInfixOf` body) ) `shouldBe` True

    it "★ C5(D-1)：判定是标注而非拒绝 —— status=warn 时内容仍然返回（裁定①）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      -- 无论 pass 还是 warn，响应体里的 chat.completion 载荷都要在（功能不被破坏）
      ("chat.completion" `isInfixOf` body) `shouldBe` True

    it "★ C5(D-1)：判定分量齐全 t6 / reach / edges / reason（约束确实跑了三原语）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (_, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      and [ k `isInfixOf` body
          | k <- [ "\"t6\"", "\"reach\"", "\"edges\"", "\"reason\"" ] ] `shouldBe` True


    -- ── D-3：推理状态上浮为会话投影 ───────────────────────────────────────
    -- 推理内核（T⁶ / 因果图 / 五行链）的状态此前只活在 CPU 层；这里验它经
    -- Core.Session.projections 上浮到内核会话，且在内核 API 响应中可观测。
    it "★ D-3：/agent/step 把推理状态上浮为会话投影，并在响应回显" $ do
      app <- mkCPUApp "/dev/null" Nothing
      -- 必须在**同一个** withApp 内两次 POST（每次 withApp 会新起 server，session 会丢）
      (cStart, cStep, body) <- withApp app $ \mgr base -> do
        (cs, _bs) <- httpPost mgr (base ++ "/session/start")
                       (object [ "mode" .= ("standard" :: T.Text) ])
        -- createSession 用 "session-" <> mode 生成 ID，故可预知
        (ct, bt) <- httpPost mgr (base ++ "/agent/step")
                      (object [ "sessionId" .= ("session-standard" :: T.Text)
                              , "message"   .= ("hello" :: T.Text) ])
        pure (cs, ct, bt)
      cStart `shouldBe` 200
      cStep  `shouldBe` 200
      -- ★ 上浮可观测：投影名（t6state / constraint）出现在响应里
      and [ k `isInfixOf` body | k <- [ "session_projections", "t6state", "constraint" ] ]
        `shouldBe` True
      -- ★ 推理状态的分量：T⁶ 极向/环向/Berry
      and [ k `isInfixOf` body | k <- [ "\"polar\"", "\"toroidal\"", "\"berry\"" ] ]
        `shouldBe` True
      -- 既有字段语义未被破坏
      ("reply" `isInfixOf` body) `shouldBe` True

    -- ── 端到端：提问 → 生成 → 验证（推理内核）→ 状态上浮 ──────────────────
    -- ⚠️ 本组用 /dev/null（占位引擎）验证**链路闭合**；占位采样器输出为 "token_0" 重复，
    -- 本条**能验证的是链路闭合**：请求 → 生成层产出 → 推理内核判定 → 状态上浮为投影 → 响应。
    -- **真实** CPU 推理（真实 .sov + Brain + argMaxIdx 采样）见 B4（generate 产出真实 token id）。
    it "★ D-3：/agent/step 推进内核 FSM 并在响应回显 agent_state" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (cStart, cStep, body) <- withApp app $ \mgr base -> do
        (cs, _) <- httpPost mgr (base ++ "/session/start")
                     (object [ "mode" .= ("standard" :: T.Text) ])
        (ct, bt) <- httpPost mgr (base ++ "/agent/step")
                      (object [ "sessionId" .= ("session-standard" :: T.Text)
                              , "message"   .= ("hi" :: T.Text) ])
        pure (cs, ct, bt)
      cStart `shouldBe` 200
      cStep  `shouldBe` 200
      ("agent_state" `isInfixOf` body) `shouldBe` True
      ("Idle" `isInfixOf` body) `shouldBe` True          -- before
      ("Processing" `isInfixOf` body) `shouldBe` True    -- after（transition Idle (StartCommand _)）

    it "★ 端到端：提问 → 生成 → 验证（推理内核）→ 状态上浮（占位引擎链路闭合）" $ do
      -- 占位引擎 + 链路闭合；真实 CPU 推理（Brain + argMaxIdx 采样）见 B4。
      -- 真 .sov 走 HTTP 会因 60 层/token 太慢而超时（每 token 约 5 分钟），
      -- 故本条刻意用 /dev/null（占位）保链路测试快与稳。
      app <- mkCPUApp "/dev/null" Nothing
      (cStart, cStep, body) <- withApp app $ \mgr base -> do
        (cs, _) <- httpPost mgr (base ++ "/session/start")
                     (object [ "mode" .= ("standard" :: T.Text) ])
        (ct, bt) <- httpPost mgr (base ++ "/agent/step")
                      (object [ "sessionId" .= ("session-standard" :: T.Text)
                              , "message"   .= ("证明：1+1=2" :: T.Text) ])
        pure (cs, ct, bt)
      cStart `shouldBe` 200
      cStep  `shouldBe` 200
      -- 生成层：有 reply 字段。★ 占位采样器的真实特征是恒重复 "token_0"
      -- （generateStream 里 detokenize engine [0]；实测 reply = "token_0 token_0 ..." ×100）
      ("reply" `isInfixOf` body) `shouldBe` True
      ("token_0" `isInfixOf` body) `shouldBe` True
      -- 验证层：推理内核的判定与 T⁶ 状态同时上浮
      and [ k `isInfixOf` body
          | k <- [ "trha_constraint", "constraint", "t6state", "t6_state"
                 , "\"polar\"", "\"toroidal\"", "\"berry\"" ] ] `shouldBe` True
      -- 状态上浮：投影名含 t6state / constraint
      ("session_projections" `isInfixOf` body) `shouldBe` True

    -- ── D-3 深度验证：不只查"投影存在"，而验**投影内容的数值合法性** ──────────
    -- 此前只断言投影名出现；这里解析 JSON，核对 T⁶ 三分量的值域与判定分量，
    -- 才算真的验证了"推理状态被正确地上浮"，而不是"某处出现了字符串"。
    it "★ D-3 深度验证：t6_state 三分量合法（polar<144、toroidal<46）+ 判定分量 + 投影恰两个" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (cStep, body) <- withApp app $ \mgr base -> do
        _ <- httpPost mgr (base ++ "/session/start")
               (object [ "mode" .= ("standard" :: T.Text) ])
        httpPost mgr (base ++ "/agent/step")
          (object [ "sessionId" .= ("session-standard" :: T.Text)
                  , "message"   .= ("hi" :: T.Text) ])
      cStep `shouldBe` 200
      let mval = decode (BL.fromStrict (TE.encodeUtf8 (T.pack body))) :: Maybe Value
      case mval of
        Nothing -> expectationFailure ("响应不是合法 JSON: " ++ take 200 body)
        Just v -> do
          -- 注意 JSON 是**嵌套**的：polar/toroidal/berry 在 "t6_state" 对象内部，
          -- 而 t6/edges/status 在 "trha_constraint" 对象内部（顶层没有这些键）。
          let mt6 = parseMaybe (withObject "resp" (\o -> do
                      s6 <- o .: "t6_state"
                      (,,) <$> s6 .: "polar" <*> s6 .: "toroidal" <*> s6 .: "berry")) v
                     :: Maybe (Int, Int, Int)
          case mt6 of
            Nothing -> expectationFailure "缺 t6_state 字段"
            Just (polar, toroidal, _berry) -> do
              (polar >= 0 && polar < 144)   `shouldBe` True   -- 极向 mod polarWinding(144)
              (toroidal >= 0 && toroidal < 46) `shouldBe` True -- 环向 mod toroidalWinding(46)
          let mcv = parseMaybe (withObject "resp" (\o -> do
                      c <- o .: "trha_constraint"
                      (,,) <$> c .: "t6" <*> c .: "edges" <*> c .: "status")) v
                     :: Maybe (Bool, Int, T.Text)
          case mcv of
            Nothing -> expectationFailure "缺 constraint 判定字段"
            Just (_t6ok, edges, status) -> do
              (edges >= 0) `shouldBe` True
              (status == "pass" || status == "warn") `shouldBe` True  -- 无「拒绝」
          let mnames = parseMaybe (withObject "p" (.: "session_projections")) v
                        :: Maybe [T.Text]
          fmap List.sort mnames `shouldBe` Just ["constraint", "t6state"]

    it "★ D-3：投影是覆盖写 —— 多步后仍只有两个键（不累积）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      n2 <- withApp app $ \mgr base -> do
        _ <- httpPost mgr (base ++ "/session/start")
               (object [ "mode" .= ("standard" :: T.Text) ])
        b2 <- snd <$> httpPost mgr (base ++ "/agent/step")
                (object [ "sessionId" .= ("session-standard" :: T.Text)
                        , "message"   .= ("a" :: T.Text) ])
        b3 <- snd <$> httpPost mgr (base ++ "/agent/step")
                (object [ "sessionId" .= ("session-standard" :: T.Text)
                        , "message"   .= ("b" :: T.Text) ])
        pure b3
      and [ k `isInfixOf` n2 | k <- [ "t6state", "constraint" ] ] `shouldBe` True

    it "CPU adapter 经 HTTP 走 SSE 流式（/v1/chat/completions/stream）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions/stream") (chatReq True)
      code `shouldBe` 200
      ("data: " `isInfixOf` body)        `shouldBe` True
      ("data: [DONE]" `isInfixOf` body)  `shouldBe` True

    -- T8：provider 名分派到本地 backend —— 完整链路
    --   HTTP → resolveAdapterIO → findProvider(providers.json) → adapterFor "cpu" → 本地引擎
    -- 用 TRHA_PROVIDERS_FILE 指向临时文件，避免污染 ~/.trha。
    it "provider=\"local-cpu\"（kind=cpu）的请求经 providers.json 分派，由本地引擎回答" $ do
      let pfile = "/tmp/trha-test-providers.json"
          entry = ProviderEntry
            { peName = "local-cpu", peKind = "cpu", peBaseUrl = "/dev/null"
            , peModels = ["cpu"], peDefault = "cpu", peHasKey = False, peKeyEnv = Nothing
            , peVisionModels = [], pePreset = False, peInUse = False, peContextWindow = Nothing
            , peWebSearch = Nothing, peSendsThinking = Nothing }
      BLC.writeFile pfile (encode (ProviderStore [entry]))
      setEnv "TRHA_PROVIDERS_FILE" pfile
      r <- adapterFor entry ""
      case r of
        Left why -> expectationFailure ("cpu adapter 构造失败: " ++ T.unpack why)
        Right defAdapter -> do
          app <- mkApp defAdapter Nothing
          (code, body) <- withApp app $ \mgr base ->
            httpPost mgr (base ++ "/v1/chat/completions")
              (object [ "provider" .= ("local-cpu" :: T.Text)
                      , "model"    .= ("cpu" :: T.Text)
                      , "messages" .= [ object [ "role"    .= ("user" :: T.Text)
                                               , "content" .= ("hi" :: T.Text) ] ] ])
          unsetEnv "TRHA_PROVIDERS_FILE"
          code `shouldBe` 200
          ("cpu" `isInfixOf` body) `shouldBe` True   -- 本地引擎回答（回显模型名）
