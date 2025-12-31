# Implementation Plan: Enums with Type Packs

## Overview

Enable enums to declare type parameter packs:

```swift
enum Result<each T> {
    case success(repeat each T)
    case failure(Error)
}

// Construction - like function calls with pack parameters
let r = Result.success(1, "hello", true)  // Result<Int, String, Bool>

// Pattern matching - bound variable has pack type
switch r {
case let .success(values):  // values: repeat each T
    print(repeat each values)
case let .failure(error):
    print(error)
}
```

## Current Status: WORKING

### Completed
- **Step 1**: Removed restriction in `TypeCheckDeclPrimary.cpp`
- **Step 2**: Type-checking for enum declarations passes
- **Step 3**: Type-checking for case construction passes
- **Step 4**: Type-checking for pattern matching passes
- **Step 5**: Fixed `visitPackElementExpr` in `SILGenLValue.cpp` to use `tuple_pack_element_addr` for tuple types
- **Step 6**: Fixed `emitTupleDispatch` in `SILGenPattern.cpp` to handle tuples with pack expansions
- **Step 7**: Fixed `visitTuplePattern` in `SILGenPattern.cpp` for noncopyable pattern matching
- **Step 8**: Fixed `bindVariable` in `SILGenPattern.cpp` to handle pack expansion types by storing tuple address directly
- **Step 9**: Fixed `getEnumElementType` in `SILType.cpp` to use the abstraction pattern with substitutions
- **Step 10**: Fixed `getConstantLabelsLength` and `emitDynamicTupleTypeLabels` in `GenPack.cpp` to handle labeled pack expansion elements

### What Works Now
1. **Declaring pack enums**: `enum Wrapper<each T> { case values(items: repeat each T) }`
2. **Labeled pack construction**: `Wrapper.values(items: repeat each values)`
3. **Labeled pattern matching**: `case let .values(items: v): _ = (repeat each v)`
4. **Full execution**: Construction, matching, and using pack elements all work

### Example (Fully Working)
```swift
enum Wrapper<each T> {
    case values(items: repeat each T)
    case empty
}

func construct<each T>(_ values: repeat each T) -> Wrapper<repeat each T> {
    return .values(items: repeat each values)
}

func printElements<each T>(_ w: Wrapper<repeat each T>) {
    switch w {
    case let .values(items: v):
        print("Elements: \((repeat each v))")
    case .empty:
        print("Empty wrapper")
    }
}

// Test output:
let w1 = construct(1, "hello", true, 3.14)
printElements(w1)  // Elements: (1, "hello", true, 3.14)
```

## Known Limitations

1. **Unlabeled pack parameters** are not yet supported:
   ```swift
   // NOT YET WORKING:
   case values(repeat each T)  // Crashes in SILGen
   ```

## Technical Findings

### Type Representation
- **AST**: Pack expansion type is `repeat each T` (PackExpansionType)
- **SIL for function params**: `$*Pack{repeat each T}` (SILPackType)
- **SIL for struct/enum storage**: `$(repeat each T)` (tuple containing PackExpansionType)

### Key Discovery: Unlabeled vs Labeled
For `composeTuple` in ASTContext.cpp:
```cpp
if (elements.size() == 1 && !elements[0].hasName())
    return elements[0].getType();  // Returns unwrapped type
return TupleType::get(elements, ctx);  // Returns tuple
```

- `case values(repeat each T)` -> payload type is `repeat each T` (unwrapped)
- `case values(items: repeat each T)` -> payload type is `(items: repeat each T)` (tuple)

The **labeled form works** because it keeps the tuple structure, which is what existing SILGen expects.

### SIL Instruction Requirements
- `createTupleElementAddr`: For simple tuples without pack expansions
- `createScalarPackIndex` + `createTuplePackElementAddr`: For scalar elements in tuples with pack expansions
- **Cannot use** `createScalarPackIndex` on pack expansion elements themselves
- For pack expansion elements: Must keep reference to whole tuple + component index

### Pattern Variable Binding
For pack expansion types stored in tuples, the pattern variable binding stores the **tuple address** directly in `VarLocs`. The element access code in `visitPackElementExpr` then uses `tuple_pack_element_addr` to access individual elements.

---

## File Changes Made

| File | Change | Status |
|------|--------|--------|
| `lib/Sema/TypeCheckDeclPrimary.cpp` | Remove restriction | Done |
| `lib/SILGen/SILGenLValue.cpp` | Handle tuple types in `visitPackElementExpr` | Done |
| `lib/SILGen/SILGenPattern.cpp` | Handle pack expansion elements in `emitTupleDispatch` | Done |
| `lib/SILGen/SILGenPattern.cpp` | Handle pack expansion elements in `visitTuplePattern` | Done |
| `lib/SILGen/SILGenPattern.cpp` | Handle pack expansion types in `bindVariable` | Done |
| `lib/SIL/IR/SILType.cpp` | Fix `getEnumElementType` to use `origEltType` with substitutions | Done |
| `lib/IRGen/GenPack.cpp` | Handle labeled pack expansion elements in `getConstantLabelsLength` | Done |
| `lib/IRGen/GenPack.cpp` | Handle labeled pack expansion elements in `emitDynamicTupleTypeLabels` | Done |

## Remaining Work (Optional Enhancement)

| File | Change | Status |
|------|--------|--------|
| `lib/SILGen/SILGenApply.cpp` | Add pack expansion support to enum payload initialization | TODO |

This would enable unlabeled pack parameters like `case values(repeat each T)`.
