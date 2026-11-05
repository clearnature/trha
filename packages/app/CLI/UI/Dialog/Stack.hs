{-# LANGUAGE OverloadedStrings #-}

-- | 对话框栈的三个操作：入栈、出栈、取栈顶。
--
-- 从 "UI.Dialog" 拆出。栈用列表表示，栈顶是 head（拥有键盘焦点）。
-- 只依赖 "UI.Dialog.Types"，不依赖其余子模块。
module UI.Dialog.Stack
  ( emptyStack
  , stackPush
  , stackPop
  , stackTop
  , stackNull
  ) where

import UI.Dialog.Types (Dialog, DialogStack)

emptyStack :: DialogStack
emptyStack = []

-- | Open a dialog on top of the stack.
stackPush :: Dialog -> DialogStack -> DialogStack
stackPush = (:)

-- | Close the top dialog; popping an empty stack is a no-op.
stackPop :: DialogStack -> DialogStack
stackPop (_ : rest) = rest
stackPop []         = []

-- | The topmost dialog, if any.
stackTop :: DialogStack -> Maybe Dialog
stackTop (d : _) = Just d
stackTop []      = Nothing

-- | Whether the stack is empty (no dialog open).
stackNull :: DialogStack -> Bool
stackNull = null

-- | Filtered item count of a dialog.
-- | 对话框标题。**12 个构造子必须齐全**——非穷尽 case 不会编译失败，只会在
-- 运行时 pattern match failure（`DialogPresets` 就这样漏过一次，见
-- docs/reference/brick-split-incident-2026-11-04.md）。
