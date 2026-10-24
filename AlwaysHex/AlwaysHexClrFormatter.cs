// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Collections.ObjectModel;
using Microsoft.VisualStudio.Debugger.Clr;
using Microsoft.VisualStudio.Debugger.ComponentInterfaces;
using Microsoft.VisualStudio.Debugger.Evaluation;
using Microsoft.VisualStudio.Debugger.Evaluation.ClrCompilation;

namespace AlwaysHex
{
  /// <summary>
  /// C#: a server-side component (level 63,100, just above Roslyn's C# result provider at
  /// 63,000) that formats integer values in both radixes where the text is produced. Unlike the
  /// C/C++ path, no result is replaced, so every debugger feature keeps the C# result provider's
  /// own results (visualizers, Object IDs, pinned members, data breakpoints, ...).
  ///
  /// Each method asks the next formatter (calling the same API on the value passes the request
  /// on to the next lower component) and only appends the other radix to plain integers.
  /// </summary>
  public sealed class AlwaysHexClrFormatter : IDkmClrFormatter, IDkmClrFormatter2
  {
    string IDkmClrFormatter.GetValueString(DkmClrValue clrValue, DkmInspectionContext inspectionContext,
        ReadOnlyCollection<string> formatSpecifiers)
    {
      return AddOtherRadix(clrValue, inspectionContext, formatSpecifiers, clrValue.GetValueString(inspectionContext, formatSpecifiers));
    }

    string IDkmClrFormatter2.GetValueString(DkmClrValue clrValue, DkmClrCustomTypeInfo customTypeInfo,
        DkmInspectionContext inspectionContext, ReadOnlyCollection<string> formatSpecifiers)
    {
      return AddOtherRadix(clrValue, inspectionContext, formatSpecifiers,
          clrValue.GetValueString(customTypeInfo, inspectionContext, formatSpecifiers));
    }

    // Editing keeps the plain value: passed on unchanged.
    string IDkmClrFormatter2.GetEditableValueString(DkmClrValue clrValue, DkmInspectionContext inspectionContext,
        DkmClrCustomTypeInfo customTypeInfo)
    {
      return clrValue.GetEditableValueString(inspectionContext, customTypeInfo);
    }

    string IDkmClrFormatter.GetTypeName(DkmInspectionContext inspectionContext, DkmClrType clrType, DkmClrCustomTypeInfo customTypeInfo,
        ReadOnlyCollection<string> formatSpecifiers)
    {
      return inspectionContext.GetTypeName(clrType, customTypeInfo, formatSpecifiers);
    }

    bool IDkmClrFormatter.HasUnderlyingString(DkmClrValue clrValue, DkmInspectionContext inspectionContext)
    {
      return clrValue.HasUnderlyingString(inspectionContext);
    }

    string IDkmClrFormatter.GetUnderlyingString(DkmClrValue clrValue, DkmInspectionContext inspectionContext)
    {
      return clrValue.GetUnderlyingString(inspectionContext);
    }

    // "100" -> "100 (0x00000064)" for the integer types; anything else (and any value with a
    // format specifier such as "a,h") is returned as the next formatter produced it.
    private static string AddOtherRadix(DkmClrValue clrValue, DkmInspectionContext inspectionContext,
        ReadOnlyCollection<string> formatSpecifiers, string value)
    {
      try
      {
        if (value == null || (formatSpecifiers != null && formatSpecifiers.Count > 0))
        {
          return value;
        }

        string type = CSharpTypeName(clrValue.HostObjectValue);

        if (type == null)
        {
          return value;
        }

        return CSharpFormatter.FormatOtherRadix(value, type, inspectionContext.Radix == 16) ?? value;
      }
      catch (Exception)
      {
        return value;
      }
    }

    // The C# keyword for a boxed integer value (as the CSharpFormatter table expects), or null.
    private static string CSharpTypeName(object hostValue)
    {
      if (hostValue == null)
      {
        return null;
      }

      switch (Type.GetTypeCode(hostValue.GetType()))
      {
        case TypeCode.SByte: return "sbyte";
        case TypeCode.Byte: return "byte";
        case TypeCode.Int16: return "short";
        case TypeCode.UInt16: return "ushort";
        case TypeCode.Char: return "char";
        case TypeCode.Int32: return "int";
        case TypeCode.UInt32: return "uint";
        case TypeCode.Int64: return "long";
        case TypeCode.UInt64: return "ulong";
        default: return null;
      }
    }
  }
}
