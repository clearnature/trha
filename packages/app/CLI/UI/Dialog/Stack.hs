{-# LANGUAGE OverloadedStrings #-}

-- | 对话框栈的三个操作：入栈、出栈、取栈顶。
--
-- 实现在 brick 的 @Brick.Widgets.Dialog.Stack@（submodule，泛型栈），
-- 这里保留 trha 原有的函数名，让 35 个引用者无需改动。
module UI.Dialog.Stack
  ( emptyStack
  , stackPush
  , stackPop
  , stackTop
  , stackNull
  ) where

import Brick.Widgets.Dialog.Stack (emptyStack, isNull, pop, push, top)
import UI.Dialog.Types (Dialog, DialogStack)

-- | Open a dialog on top of the stack.
stackPush :: Dialog -> DialogStack -> DialogStack
stackPush = push

-- | Close the top dialog; popping an empty stack is a no-op.
stackPop :: DialogStack -> DialogStack
stackPop = pop

-- | The topmost dialog, if any.
stackTop :: DialogStack -> Maybe Dialog
stackTop = top

-- | Whether the stack is empty (no dialog open).
stackNull :: DialogStack -> Bool
stackNull = isNull
