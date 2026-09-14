#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
constexpr UINT kTerminalPtyEventMessage = WM_APP + 81;
void RegisterTerminalPtyChannel(flutter::BinaryMessenger* messenger, HWND window);
bool HandleTerminalPtyWindowMessage(UINT message, LPARAM lparam);
