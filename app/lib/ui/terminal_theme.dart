/**
 * 终端配色：与设计稿一致的深色终端主题（浅色与深色模式下终端都保持深色）。
 */
library;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/** pdTerminalTheme：终端配色 */
const pdTerminalTheme = TerminalTheme(
  cursor: Color(0xFFD8D8D8),
  selection: Color(0x5507C160),
  foreground: Color(0xFFD8D8D8),
  background: Color(0xFF1E1E1E),
  black: Color(0xFF1E1E1E),
  red: Color(0xFFEB5757),
  green: Color(0xFF6FCF97),
  yellow: Color(0xFFF2C94C),
  blue: Color(0xFF5CA8E0),
  magenta: Color(0xFFBB6BD9),
  cyan: Color(0xFF56CCF2),
  white: Color(0xFFD8D8D8),
  brightBlack: Color(0xFF9A9A9A),
  brightRed: Color(0xFFFF7B7B),
  brightGreen: Color(0xFF8BE0AE),
  brightYellow: Color(0xFFFFDB6E),
  brightBlue: Color(0xFF7FBEF0),
  brightMagenta: Color(0xFFD08BF0),
  brightCyan: Color(0xFF7FDBF8),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFF2C94C),
  searchHitBackgroundCurrent: Color(0xFF07C160),
  searchHitForeground: Color(0xFF1E1E1E),
);

/** 终端界面上的次要文字色 */
const pdTerminalMuted = Color(0xFF999999);
