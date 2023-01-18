#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2023 Yanis Zafirópulos
#
# @file: vm/eval.nim
#=======================================================

## This module contains the evaluator for the VM.
## 
## The evaluator:
## - takes a Block of values coming from the parser
## - passes to the AST generator
## - interpretes the AST and returns a Translation object
## 
## The main entry point is ``doEval``.

#=======================================
# Libraries
#=======================================

import hashes, tables

import vm/[ast, bytecode, values/value]
import vm/values/custom/[vbinary, vlogical]

import vm/values/printable

#=======================================
# Variables
#=======================================

var
    StoredTranslations : Table[Hash, Translation]

#=======================================
# Helpers
#=======================================

func indexOfValue(a: ValueArray, item: Value): int {.inline,enforceNoRaises.}=
    result = 0
    for i in items(a):
        if consideredEqual(item, i): return
        inc(result)
    result = -1

template addToInstructions(b: untyped):untyped {.dirty.} =
    when b is OpCode:
        instructions.add(byte(b))
    else:
        instructions.add(b)

proc addConst(consts: var ValueArray, instructions: var VBinary, v: Value, op: OpCode) {.inline,enforceNoRaises.} =
    var indx = consts.indexOfValue(v)
    if indx == -1:
        let newv = v
        newv.readonly = true
        consts.add(newv)
        indx = consts.len-1

    if indx <= 13:
        addToInstructions((byte(op)-0x0E) + byte(indx))
    else:
        if indx>255:
            addToInstructions([
                byte(indx),
                byte(indx shr 8),
                byte(op)+1
            ])
        else:
            addToInstructions([
                byte(indx),
                byte(op)
            ])

#=======================================
# Methods
#=======================================

proc evaluateBlock*(blok: Node, isDictionary=false): Translation =
    var consts: ValueArray
    var it: VBinary

    let nLen = blok.children.len
    var i {.register.} = 0

    #------------------------
    # Shortcuts
    #------------------------

    template addConst(v: Value, op: OpCode): untyped =
        addConst(consts, it, v, op)

    template addByte(b: untyped): untyped = 
        when b is OpCode:
            it.add(byte(b))
        else:
            it.add(b)

    #------------------------
    # MainLoop
    #------------------------

    while i < nLen:
        let item = blok.children[i]

        echo "current item:"
        echo dumpNode(item)

        for instruction in traverse(item):
            echo "processing: "
            echo dumpNode(instruction)
            case instruction.kind:
                of RootNode:
                    discard
                of ConstantValue:
                    var alreadyPut = false
                    let iv {.cursor.} = instruction.value
                    case instruction.value.kind:
                        of Integer:
                            if likely(iv.iKind==NormalInteger) and iv.i>=0 and iv.i<=15: 
                                addByte(byte(opConstI0) + byte(iv.i))
                                alreadyPut = true
                        of Floating:
                            if iv.f == 0.0:
                                addByte(opConstF0)
                                alreadyPut = true
                            elif iv.f == 1.0:
                                addByte(opConstF1)
                                alreadyPut = true
                            elif iv.f == 2.0:
                                addByte(opConstF2)
                                alreadyPut = true
                        of String:
                            if iv.s == "":
                                addByte(opConstS)
                                alreadyPut = true
                        of Block:
                            if iv.a.len == 0:
                                addByte(opConstA)
                                alreadyPut = true
                        of Logical:
                            if iv.b == True:
                                addByte(opConstBT)
                                alreadyPut = true
                            elif iv.b == False:
                                addByte(opConstBF)
                                alreadyPut = true
                        else:
                            discard

                    if not alreadyPut:
                        addConst(instruction.value, opPush)
                of VariableLoad:
                    addConst(instruction.value, opLoad)
                of VariableStore:
                    addConst(instruction.value, opStore)
                of OtherCall:
                    addConst(instruction.value, opCall)
                of BuiltinCall:
                    addByte(instruction.op)
                of SpecialCall:
                    discard # TOFIX!

        i += 1

    result = Translation(constants: consts, instructions: it)

#=======================================
# Main
#=======================================

proc doEval*(root: Value, isDictionary=false, useStored: static bool = true): Translation {.inline.} = 
    ## Take a parsed Block of values and return its Translation - 
    ## that is: the constants found + the list of bytecode instructions
    
    var vhash {.used.}: Hash = -1
    
    when useStored:
        if not root.dynamic:
            vhash = hash(root)
            if (let storedTranslation = StoredTranslations.getOrDefault(vhash, nil); not storedTranslation.isNil):
                return storedTranslation

    result = evaluateBlock(generateAst(root), isDictionary=isDictionary)
    result.instructions.add(byte(opEnd))

    dump(newBytecode(result))

    when useStored:
        if vhash != -1:
            StoredTranslations[vhash] = result

template evalOrGet*(item: Value): untyped =
    if item.kind==Bytecode: item.trans
    else: doEval(item)