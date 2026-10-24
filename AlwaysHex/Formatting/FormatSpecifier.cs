// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

namespace AlwaysHex
{
  /// <summary>
  /// Detects explicit format specifiers in Watch expressions ("a,x", "p,10", "s,su"). Such
  /// expressions are left to the EE alone, because the user asked for one specific format.
  /// </summary>
  internal static class FormatSpecifier
  {
    // A specifier is a comma outside of brackets and string/char literals; commas inside
    // "f(a, b)" or "arr[i, j]" do not count.
    // C# verbatim strings (@"...", $@"...", @$"...") have no backslash escapes; their
    // doubled quote "" simply ends and restarts the string, which keeps commas inside.
    internal static bool HasFormatSpecifier(string text)
    {
      if (string.IsNullOrEmpty(text))
      {
        return false;
      }

      int depth = 0;
      bool inString = false;
      bool verbatim = false;
      char quote = '\0';

      for (int i = 0; i < text.Length; i++)
      {
        char c = text[i];

        if (inString)
        {
          if (c == '\\' && !verbatim)
          {
            i++;
          }
          else if (c == quote)
          {
            inString = false;
          }

          continue;
        }

        switch (c)
        {
          case '"':
          case '\'':
            inString = true;
            quote = c;
            verbatim = c == '"' && i > 0 && (text[i - 1] == '@' || (i > 1 && text[i - 1] == '$' && text[i - 2] == '@'));
            break;
          case '(':
          case '[':
          case '{':
            depth++;
            break;
          case ')':
          case ']':
          case '}':
            depth--;
            break;
          case ',':
            if (depth == 0)
            {
              return true;
            }

            break;
        }
      }

      return false;
    }
  }
}
