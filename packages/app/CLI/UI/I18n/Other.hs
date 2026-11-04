{-# LANGUAGE OverloadedStrings #-}

-- | 非中文词表：法语/西班牙语/俄语/泰语/藏语/彝文/缅甸语。
-- 除法语、西班牙语外都是骨架（术语待母语者校对前回退英文）。
module UI.I18n.Other
  ( frDict, esDict, ruDict, thDict, boDict, iiDict, myDict
  ) where

import qualified Data.Map as M
import Data.Text (Text)

-- | French skeleton.
frDict :: M.Map Text Text
frDict = M.fromList
  [ ("Show this help", "Afficher cette aide")
  , ("Exit the application", "Quitter l'application")
  , ("Session: ", "Session : ")
  , ("Model: ", "Modèle : ")
  , ("Ready", "Prêt")
  , ("Error", "Erreur")
  , ("Commands:", "Commandes :")
  , ("Show current session/model status", "Afficher l'état de la session/du modèle")
  , ("Settings:", "Paramètres :")
  , ("Commands", "Commandes")
  , ("Error", "Erreur")
  , ("Workspace: ", "Espace de travail : ")
  , ("Git branch: ", "Branche Git : ")
  , ("context ", "contexte ")
  , ("compact ", "compression ")
  , ("turn hit ", "touché ce tour ")
  , ("Available keys:", "Clés disponibles :")
  , ("Unknown setting key: ", "Clé de réglage inconnue : ")
  , ("Tokens: ", "Tokens : ")
  , ("Show current session/model status", "Afficher l'état de la session/du modèle")
  ]

-- | German skeleton.

-- | Spanish skeleton.
esDict :: M.Map Text Text
esDict = M.fromList
  [ ("Show this help", "Mostrar esta ayuda")
  , ("Exit the application", "Salir de la aplicación")
  , ("Session: ", "Sesión: ")
  , ("Model: ", "Modelo: ")
  , ("Ready", "Listo")
  , ("Error", "Error")
  , ("Commands:", "Comandos:")
  , ("Show current session/model status", "Mostrar el estado de la sesión/modelo")
  , ("Settings:", "Ajustes:")
  , ("Commands", "Comandos")
  , ("Error", "Error")
  , ("Workspace: ", "Espacio de trabajo: ")
  , ("Git branch: ", "Rama Git: ")
  , ("context ", "contexto ")
  , ("compact ", "compresión ")
  , ("turn hit ", "aciertos ")
  , ("Available keys:", "Claves disponibles:")
  , ("Unknown setting key: ", "Clave de ajuste desconocida: ")
  , ("Tokens: ", "Tokens: ")
  , ("Show current session/model status", "Mostrar el estado de la sesión/modelo")
  ]

ruDict, thDict :: M.Map Text Text
ruDict = M.fromList
  [ ("Show this help", "Показать справку")
  , ("Exit the application", "Выйти из приложения")
  , ("Session: ", "Сеанс: ")
  , ("Ready", "Готово")
  , ("Model: ", "Модель: ")
  , ("Error", "Ошибка")
  , ("Commands:", "Команды:")
  , ("Show current session/model status", "Показать состояние сеанса/модели")
  , ("Settings:", "Настройки:")
  , ("Commands", "Команды")
  , ("Error", "Ошибка")
  , ("Workspace: ", "Рабочая область: ")
  , ("Git branch: ", "Ветка Git: ")
  , ("context ", "контекст ")
  , ("compact ", "сжатие ")
  , ("turn hit ", "попаданий ")
  , ("Available keys:", "Доступные ключи:")
  , ("Unknown setting key: ", "Неизвестный ключ настройки: ")
  , ("Tokens: ", "Токены: ")
  , ("Show current session/model status", "Показать состояние сеанса/модели")
  ]
thDict = M.fromList
  [ ("Show this help", "แสดงความช่วยเหลือนี้")
  , ("Exit the application", "ออกจากแอปพลิเคชัน")
  , ("Session: ", "เซสชัน: ")
  , ("Ready", "พร้อม")
  , ("Model: ", "โมเดล: ")
  , ("Error", "ข้อผิดพลาด")
  , ("Commands:", "คำสั่ง:")
  , ("Show current session/model status", "แสดงสถานะเซสชัน/โมเดล")
  , ("Settings:", "การตั้งค่า:")
  , ("Commands", "คำสั่ง")
  , ("Workspace: ", "พื้นที่ทำงาน: ")
  , ("Git branch: ", "สาขา Git: ")
  , ("context ", "บริบท ")
  , ("compact ", "การบีบอัด ")
  , ("turn hit ", "ตรงรอบนี้ ")
  , ("Available keys:", "คีย์ที่ใช้ได้:")
  , ("Unknown setting key: ", "ไม่รู้จักคีย์การตั้งค่า: ")
  , ("Tokens: ", "โทเค็น: ")
  , ("Show current session/model status", "แสดงสถานะเซสชัน/โมเดล")
  ]
boDict, iiDict, myDict :: M.Map Text Text
-- 缅甸文：骨架 + 常用界面词（待母语校对）。
myDict = M.fromList
  [ ("Show this help", "ဤအကူအညီကို ပြပါ")
  , ("Exit the application", "အက်ပ်မှ ထွက်ပါ")
  , ("Session: ", "စက်ရှင်: ")
  , ("Ready", "အသင့်")
  , ("Error", "အမှား")
  , ("Model: ", "မော်ဒယ်: ")
  , ("Commands:", "အမိန့်များ:")
  , ("Commands", "အမိန့်များ")
  , ("Settings:", "ဆက်တင်များ:")
  , ("Workspace: ", "အလုပ်နေရာ: ")
  , ("Git branch: ", "Git ဌာနခွဲ: ")
  , ("context ", "အကြောင်းအရာ ")
  , ("compact ", "ကျစ်လျစ် ")
  , ("turn hit ", "ဤအကြိမ် ထိမှန် ")
  , ("Available keys:", "ရနိုင်သော သော့များ:")
  , ("Unknown setting key: ", "မသိသော ဆက်တင်သော့: ")
  , ("Tokens: ", "တိုကင်များ: ")
  , ("Show current session/model status", "လက်ရှိ စက်ရှင်/မော်ဒယ် အခြေအနေကို ပြပါ")
  ]
-- 藏文：只收录能确认的常用词；其余回退英文，避免伪造翻译（待母语校对）。
boDict = M.fromList
  [ ("Show this help", "རོགས་རམ་འདི་སྟོན")
  , ("Exit the application", "མཉེན་ཆས་ལས་ཕྱིར་ཐོན")
  , ("Ready", "གྲ་སྒྲིག")
  , ("Error", "ནོར་འཁྲུལ")
  ]
-- 彝文（Nuosu）：骨架；术语待母语者校对前全部回退英文。
iiDict = M.fromList
  [ ("Ready", "ꄀꄉ")
  , ("Error", "ꆏꃅ")
  ]
