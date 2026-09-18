{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Inference
  ( -- * Inference Engine
    InferenceEngine(..)
  , Brain(..)
  , createInferenceEngine
  , withBrain
  , withWeights
  , withWeightsC
  , loadModel
  , generate
  , generateStream
  , tokenize
  , detokenize
  , escTok
  ) where

import Infrastructure.CPU.Types
import Infrastructure.CPU.Ops
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer (WuxingConfig, WuxingLayerW, argMaxIdx)
import Infrastructure.CPU.SovereignIntrinsic (SovereignIntWeights)
import Infrastructure.CPU.SovereignFull
  ( brainStepToken, sovereignForwardFull, sovereignForwardFullCompact
  , SovereignIntWeightsC )
import qualified Infrastructure.CPU.SovereignTypes as ST
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString as BS
import qualified Data.Char as C
import Data.List (nub)
import Foreign.Ptr
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Marshal.Array (peekArray, pokeArray)

-- | 「大脑」：本地 CPU 草稿推理所需的结构配置（.sov + 层/相位/wuxing 权重）。
-- 从 'loadWuxingFromSov' 载入 wuxing 权重后，配合真实 .sov 即可产出 logits。
data Brain = Brain
  { brainSovPath :: FilePath          -- ^ 真实 .sov 路径
  , brainConfig  :: SovereignConfig   -- ^ 层/深度/heads/vocab/ff
  , brainWuxing  :: WuxingConfig
  , brainWuxingW :: WuxingLayerW
  , brainWeights :: Maybe SovereignIntWeights  -- ^ 预载整包权重（装箱版，40GB）
  , brainWeightsC :: Maybe SovereignIntWeightsC -- ^ 紧凑 C 链权重（≈5GB，**优先使用**）
  }

-- | 带预载权重的 Brain（装箱版：每 token 不再重读 .sov / 重解包）。
withWeights :: SovereignIntWeights -> Brain -> Brain
withWeights w b = b { brainWeights = Just w }

-- | 带**紧凑 C 链权重**的 Brain（'loadWeightsSovC' 产物；realStream 优先走它）。
-- ⚠️ 每个 token 的 'sovereignForwardFullCompact' 只传指针（权重常驻 VS.Vector），
-- 不再重建 'CIntLayer' —— 60 层稳态实测 1.9s/token（r-mu61lc0p-kf1fgk）。
withWeightsC :: SovereignIntWeightsC -> Brain -> Brain
withWeightsC w b = b { brainWeightsC = Just w }

-- | Inference engine
data InferenceEngine = InferenceEngine
  { engineBackend :: CPUBackend
  , engineModelPath :: FilePath
  , engineVocabSize :: Int
  , engineEmbedDim :: Int
  , engineNumLayers :: Int
  , engineNumHeads :: Int
  , engineBrain :: Maybe Brain
  -- ^ WebGPU 前向句柄（弱耦合：上层注入，避免 trha-llm ↔ trha-gpu-infer 依赖环）。
  -- 签名与 'sovereignForwardFullCompact' 对齐：@[Int] -> IO (Either String [[GF27]])@。
  , engineGPU :: Maybe ([Int] -> IO (Either String [[Int]]))
  -- ^ 用 Int 编码（0..26）跨库传递，规避共享 src 双类型陷阱（GF27 会被各库重编）
  }

-- | Create a new inference engine
createInferenceEngine :: CPUBackend -> FilePath -> IO InferenceEngine
createInferenceEngine backend modelPath = do
  -- Load model metadata (placeholder); real dims are read when a Brain is attached.
  let vocabSize = 32000
  let embedDim = 4096
  let numLayers = 32
  let numHeads = 32
  return $ InferenceEngine backend modelPath vocabSize embedDim numLayers numHeads Nothing Nothing

-- | 把真实大脑挂到引擎上（CPU 草稿推理路径）。
withBrain :: Brain -> InferenceEngine -> InferenceEngine
withBrain b e = e { engineBrain = Just b, engineVocabSize = scVocab (brainConfig b) }

-- | Load a model
loadModel :: InferenceEngine -> IO (Either String ())
loadModel engine = do
  -- Load model weights (placeholder)
  putStrLn $ "Loading model: " ++ engineModelPath engine
  return $ Right ()

-- | Generate text, handing each token's text to the callback the moment it is
-- produced.  @generate@ is this function with a no-op callback, so the
-- blocking and the streaming path can never drift apart — and a real engine
-- only ever has to replace the sampling step inside this one loop.
generateStream :: InferenceEngine -> Text -> Int -> (Text -> IO ()) -> IO (Either String Text)
generateStream engine prompt maxTokens onToken = case engineBrain engine of
  Nothing -> placeholderStream engine prompt maxTokens onToken
  Just brain -> realStream brain engine prompt maxTokens onToken

-- | 占位采样（无 Brain 时的历史行为，保持兼容：产出 token_0 序列；
-- 不受 detokenize 升级影响 —— token 0 现在是空格字符，这里用字面量占位）。
placeholderStream :: InferenceEngine -> Text -> Int -> (Text -> IO ()) -> IO (Either String Text)
placeholderStream _engine _prompt maxTokens onToken = do
  let go acc 0 = return acc
      go acc n = do
        let word  = "token_0"
            piece = if T.null acc then word else " " <> word
            acc'  = acc <> piece
        onToken piece
        go acc' (n - 1)
  output <- go "" maxTokens
  return $ Right output

-- | 真实 CPU 草稿推理：prompt → （真 token 化）→ 逐 token 跑
-- @brainStepToken@（流式完整链路 + argMaxIdx 采样）→ 聚合文本。
-- tokenize/detokenize 是真 token 化（白名单 1:1 + escape，可逆、零越界），
-- **采样出的 token id 来自真实前向**（B3c 已验证真实 .sov 产合法 id）。
--
-- ⚠️ 性能（2026-09-17 修正）：模型**逐 token 独立**（bench3 实测：
-- `forwardStreamingFull [1]` 与 `[1,3,5]` 中 token 1 的 logits 逐位一致），
-- 所以生成时**不能**把整条已生成序列喂回去（O(N²) 白算）——
-- 每步只喂「上一步采样出的那个 token」，单 token 前向即得下一个 logits。
realStream :: Brain -> InferenceEngine -> Text -> Int -> (Text -> IO ()) -> IO (Either String Text)
realStream brain engine prompt maxTokens onToken = do
  let Brain { brainSovPath = sov, brainConfig = cfg
            , brainWuxing = wcfg, brainWuxingW = wl, brainWeights = mw
            , brainWeightsC = mwC } = brain
      -- prompt 只影响「最后那个 token」的 logits（模型独立），故取最后一个即可。
      -- ⚠️ 字符级 token 化后：白名单 token ≤ ~170，任何 ≥ 512 的 token 是
      -- escape 三元组的 hi/lo 分量（非字符），不能当种子 → 兜底 [0]（空格）。
      seed = case reverse (tokenize engine prompt) of
        (s : _) | s < escTok -> [s]
        _                    -> [0]
      -- 预载权重 → 内存前向（快：每 token 只算不重解包）；否则流式前向（慢，逐层读盘）
      go acc _ 0 = return (Right acc)
      go acc prev n = do
        r <- case engineGPU engine of
          Just gpuFwd -> do
            gres <- gpuFwd prev
            pure $ case gres of
              Right (l : _) -> Right (argMaxIdx (map ST.mkGF27 l), map ST.mkGF27 l)
              Right []      -> Left "gpu forward: empty logits"
              Left e        -> Left e
          Nothing -> case (mwC, mw) of
            -- ① 紧凑 C 链（推荐：权重常驻 VS.Vector，60 层 ≈1.9s/token）
            (Just wc, _) -> do
              lr <- sovereignForwardFullCompact cfg wc wcfg wl prev
              pure $ case lr of
                (l : _) -> Right (argMaxIdx l, l)
                []      -> Left "compact forward: empty logits"
            -- ② 装箱整包（旧路径：40GB，仅小模型/小深度可用）
            (Nothing, Just w) -> pure $ case sovereignForwardFull cfg w wcfg wl prev of
              (l : _) -> Right (argMaxIdx l, l)
              []      -> Left "memory forward: empty logits"
            -- ③ 流式（每 token 重读 .sov + 解包，200s/token 老路径）
            (Nothing, Nothing) -> brainStepToken sov cfg wcfg wl prev
        case r of
          Left e -> return (Left e)
          Right (tok, _logits) -> do
            let piece = detokenize engine [tok]
                acc'  = acc <> piece   -- 字符级：空格是合法 token(0)，由其自身还原，勿再插分隔
            onToken piece
            go acc' [tok] (n - 1)
  go "" seed maxTokens

-- | Generate text (blocking entry point).
generate :: InferenceEngine -> Text -> Int -> IO (Either String Text)
generate engine prompt maxTokens =
  generateStream engine prompt maxTokens (\_ -> return ())

-- | Tokenize text. 真 token 化（可逆、零碰撞）：
-- 白名单（ASCII 可打印 @[' '..'~']@ → 0..94，数学符号 → 95..）1:1 唯一 token，
-- 白名单外任意 Unicode 字符 → escape 三元组 [escTok, cp div 1536, cp mod 1536]
-- （cp ≤ 0x10FFFF ⇒ 两个分量 ≤ 725 / 1535 < 1536，永不越界）。
-- 约束：token ∈ [0, 1536)（engineVocabSize = scVocab = 1536）。
tokenize :: InferenceEngine -> Text -> [Int]
tokenize _engine text =
  concatMap enc (T.unpack text)
  where
    enc c = case lookup c whitelist of
      Just i  -> [i]
      Nothing -> let cp = fromEnum c
                 in [escTok, cp `div` escBase, cp `mod` escBase]

-- | Detokenize tokens. 可逆还原；未知 token / 残缺 escape → 可辨识占位（不崩溃）。
detokenize :: InferenceEngine -> [Int] -> Text
detokenize _engine tokens = T.pack (go tokens)
  where
    go [] = ""
    go (i:rest)
      | i == escTok = case rest of
          (hi:lo:r) -> let cp = hi * escBase + lo
                       in if cp <= 0x10FFFF
                            then C.chr cp : go r
                            else '⊞' : go r
          _ -> '⊞' : go rest
      | otherwise = case lookup i revTable of
          Just c -> c : go rest
          Nothing -> "token_" ++ show i ++ go rest

-- | 白名单字符 → token（ASCII 可打印 + 常用数学符号）。
whitelist :: [(Char, Int)]
whitelist = zip ([' ' .. '~'] ++ mathSymbols) [0 ..]

-- | 数学符号白名单（nub：消除书写重复，保证 lookup 唯一）。
mathSymbols :: [Char]
mathSymbols = nub "∀∃⊕⊗⊘⊙δΔλΛΣΠαβγδεθικμνξπρστυφχψωΩ∞≠≤≥≡≈∈∉∪∩⊂⊃⇒⇔→↦¬∧∨✓✗±−×÷√∑∫∂⋯⟨⟩[]{}⟨⟩·"

revTable :: [(Int, Char)]
revTable = [(i, c) | (c, i) <- whitelist]

-- | escape 标记与 base（[escTok, hi, lo] 三 token 表示一个白名单外字符）。
escTok :: Int
escTok = 512
escBase :: Int
escBase = 1536

-- | Compute logits for next token
computeLogits :: InferenceEngine -> [Int] -> IO [Float]
computeLogits engine tokens = do
  -- Placeholder: compute logits using CPU backend
  let vocabSize = engineVocabSize engine
  return $ replicate vocabSize 0.0

-- | Sample next token
sampleToken :: [Float] -> IO Int
sampleToken logits = do
  -- Placeholder: sample from logits
  return 0