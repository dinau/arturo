#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2023 Yanis Zafirópulos
#
# @file: vm/ast.nim
#=======================================================

## This module contains the AST implementation for the VM.
## 
## In a few words, it:
## - takes a Block of values coming from the parser
## - transforms it into an AST tree with semantics
##   ready for the evaluator
## 
## The main entry point is ``generateAst``.


# TODO:
# - [x] make Attribute's work
# - [x] make AttributeLabel's work
# - [x] make Path's work
# - [x] make PathLabel's work
# - [ ] make Newline values work
# - [ ] create new opCode for append
# - [ ] optimize appends
# - [ ] make labels store new functions in TmpArities
# - [ ] make if/if?/else/while/switch work

#=======================================
# Libraries
#=======================================

import hashes, strutils, sugar
import tables, unicode, std/with

import vm/[globals, values/value, values/comparison, values/types]
import vm/values/printable
import vm/values/custom/[vbinary, vcolor, vcomplex, vlogical, vrational, vsymbol, vversion]

import vm/bytecode
#=======================================
# Types
#=======================================

type
    # abstract syntax tree definition
    NodeKind* = enum
        RootNode            # Root node of the AST
        
        # TerminalNode
        ConstantValue       # Terminal node of the AST containing a value
        VariableLoad        # Load a variable

        # CallNode
        AttributeNode       # Either an Attribute or an AttributeLabel
        VariableStore       # Store a variable

        OtherCall           # Call to a function that is not a builtin
        BuiltinCall         # Call to a builtin function
        SpecialCall         # Call to a special function

    NodeArray* = seq[Node]

    Node* = ref object
        case kind*: NodeKind:
            of RootNode, ConstantValue, VariableLoad:
                discard
            else:
                op*: OpCode
                arity*: int8
                params*: int8
                
        value*: Value
        parent*: Node
        children*: NodeArray

    NodeObj = typeof(Node()[])

# Benchmarking
{.hints: on.}
{.hint: "Node's inner type is currently " & $sizeof(NodeObj) & ".".}
{.hints: off.}

#=======================================
# Variables
#=======================================
        
var
    TmpArities : Table[string,int8]
    ArrowBlock : ValueArray
    OldChild  : Node
    OldParent : Node

#=======================================
# Constants
#=======================================

const
    TerminalNode    : set[NodeKind] = {ConstantValue, VariableLoad}
    CallNode        : set[NodeKind] = {AttributeNode..SpecialCall}

#=======================================
# Forward declarations
#=======================================

proc dumpNode*(node: Node, level = 0, single: static bool=false): string 

#=======================================
# Helpers
#=======================================

#------------------------
# Tree manipulation
#------------------------

func setOnlyChild(node: Node, child: Node) {.enforceNoRaises.} =
    child.parent = node
    node.children.setLen(1)
    node.children[0] = child

func addChild*(node: Node, child: Node) {.enforceNoRaises.} =
    child.parent = node
    node.children.add(child)
    if node.kind in CallNode and child.kind != AttributeNode:
        node.params += 1

func addChildren*(node: Node, children: NodeArray) {.enforceNoRaises.} =
    for child in children:
        node.addChild(child)

func deleteNode(node: Node) =
    if not node.parent.isNil:
        node.parent.children.delete(node.parent.children.find(node))
        node.parent = nil

proc replaceNode(node: Node, newNode: Node) =
    newNode.parent = node.parent
    node.parent.children[node.parent.children.find(node)] = newNode

#------------------------
# Iterators
#------------------------

iterator traverse*(node: Node): Node =
    # reverse post-order traversal (RLN)
    var preStack = @[node]
    var postStack: seq[Node]

    while preStack.len > 0:
        var subnode = preStack.pop() 
        postStack.add(subnode)
        var j = subnode.children.len-1
        while j >= 0:
            preStack.add(subnode.children[j])
            j -= 1

    while postStack.len > 0:
        var subnode = postStack.pop()
        yield subnode

iterator traverseLRN*(node: Node): Node =
    # post-order traversal (LRN)
    var preStack = @[node]
    var postStack: seq[Node]

    while preStack.len > 0:
        var subnode = preStack.pop() 
        postStack.add(subnode)
        preStack.add(subnode.children)
    while postStack.len > 0:
        var subnode = postStack.pop()
        yield subnode

#------------------------
# Misc
#------------------------

template isSymbol(val: Value, sym: VSymbol): bool =
    val.kind == Symbol and val.m == sym

#=======================================
# Constructors
#=======================================

template newRootNode(): Node =
    Node(
        kind: RootNode
    )

template newTerminalNode(kn: NodeKind, va: Value): Node =
    Node(
        kind: kn,
        value: va
    )

template newConstant(v: Value): Node =
    newTerminalNode(ConstantValue, v)

template newVariable(v: Value): Node =
    newTerminalNode(VariableLoad, v)

template newCallNode(kn: NodeKind, ar: int8, va: Value, oper: OpCode = opNop): Node =
    Node(
        kind: kn,
        arity: ar,
        op: oper,
        value: va
    )

#=======================================
# Methods
#=======================================

proc processBlock*(root: Node, blok: Value, start = 0, processingArrow: static bool = false): int =
    var i: int = start
    var nLen: int = blok.a.len

    var current = root

    #------------------------
    # Optimization
    #------------------------

    proc optimizeAdd(target: var Node) {.enforceNoRaises.} =
        var left = target.children[0]
        var right = target.children[1]

        if left.kind == ConstantValue and left.value.kind in {Integer, Floating}:
            # Constant folding
            if right.kind == ConstantValue and right.value.kind in {Integer, Floating}:
                target.replaceNode(newConstant(left.value + right.value))
            # Convert 1 + X -> inc X
            elif left.value == I1:
                target.op = opInc
                target.arity = 1
                target.setOnlyChild(right)
        
        # Convert X + 1 -> inc X
        elif right.kind == ConstantValue and right.value == I1:
            target.op = opInc
            target.arity = 1
            target.setOnlyChild(left)
        
        # Convert X + X * Y -> X * (1 + Y) and
        #         X + Y * X -> X * (Y + 1)
        elif left.kind == VariableLoad and right.op == opMul:
            if right.children[0].kind == VariableLoad and right.children[0].value == left.value:
                target.op = opMul
                if right.children[1].kind == ConstantValue and right.children[1].value.kind in {Integer, Floating}:
                    right.replaceNode(newConstant(right.children[1].value + I1))
                else:
                    right.op = opAdd
                    right.children[0].value = newInteger(1)
            elif right.children[1].kind == VariableLoad and right.children[1].value == left.value:
                target.op = opMul
                if right.children[0].kind == ConstantValue and right.children[0].value.kind in {Integer, Floating}:
                    right.replaceNode(newConstant(right.children[0].value + I1))
                else:
                    right.op = opAdd
                    right.children[1].value = newInteger(1)
        
        # Convert (X * Y) + X -> (1 + Y) * X and
        #         (Y * X) + X -> (Y + 1) * X
        elif right.kind == VariableLoad and left.op == opMul:
            if left.children[0].kind == VariableLoad and left.children[0].value == right.value:
                target.op = opMul
                if left.children[1].kind == ConstantValue and left.children[1].value.kind in {Integer, Floating}:
                    left.replaceNode(newConstant(left.children[1].value + I1))
                else:
                    left.op = opAdd
                    left.children[0].value = newInteger(1)
            elif left.children[1].kind == VariableLoad and left.children[1].value == right.value:
                target.op = opMul
                if left.children[0].kind == ConstantValue and left.children[0].value.kind in {Integer, Floating}:
                    left.replaceNode(newConstant(left.children[0].value + I1))
                else:
                    left.op = opAdd
                    left.children[1].value = newInteger(1)

    proc optimizeSub(target: var Node) {.enforceNoRaises.} =
        var left = target.children[0]
        var right = target.children[1]

        if left.kind == ConstantValue and right.kind == ConstantValue:
            # Constant folding
            target.replaceNode(newConstant(left.value - right.value))
        elif right.kind == ConstantValue and right.value == I1:
            # Convert X - 1 -> dec X
            target.op = opDec
            target.arity = 1
            target.setOnlyChild(left)

    template optimizeArithmeticOp(target: var Node, op: untyped) =
        var left = target.children[0]
        var right = target.children[1]

        if left.kind == ConstantValue and right.kind == ConstantValue:
            target.replaceNode(newConstant(op(left.value,right.value)))

    proc optimizeUnless(target: var Node) {.enforceNoRaises.} =
        target.op = 
            if target.op == opUnless:
                opIf
            else:
                opIfE

        var left = target.children[0]

        case left.op:
            of opEq   : left.op = opNe
            of opNe   : left.op = opEq
            of opLt   : left.op = opGe
            of opLe   : left.op = opGt
            of opGt   : left.op = opLe
            of opGe   : left.op = opLt
            of opNot  :
                let newNode = left.children[0]
                newNode.parent = target
                target.children[0] = newNode
            else:
                let newNode = newCallNode(BuiltinCall, 1, nil, opNot)
                newNode.children = @[left]
                target.children[0] = newNode
                for child in newNode.children:
                    child.parent = newNode

                newNode.parent = target

    #------------------------
    # Helper Functions
    #------------------------

    template rewindCallBranches(target: var Node, optimize: bool = false): untyped =
        while target.kind in CallNode and target.params == target.arity:
            when optimize:
                case target.op:
                    of opAdd      : target.optimizeAdd()
                    of opSub      : target.optimizeSub()
                    of opMul      : target.optimizeArithmeticOp(`*`)
                    of opDiv      : target.optimizeArithmeticOp(`/`)
                    of opFDiv     : target.optimizeArithmeticOp(`//`)
                    of opMod      : target.optimizeArithmeticOp(`%`)
                    of opPow      : target.optimizeArithmeticOp(`^`)
                    of opUnless   : target.optimizeUnless()
                        
                    else:
                        discard

            target = target.parent

    template rollThrough(target: var Node): untyped =
        target = target.children[^1]

    #------------------------
    # AST Generation
    #------------------------

    proc addCall(target: var Node, name: string, arity: int8 = -1, fun: Value = nil) =
        var callType: OtherCall..SpecialCall = OtherCall

        var fn {.cursor.}: Value =
            if fun.isNil:
                GetSym(name)
            else:
                fun

        var ar: int8 =
            if arity == -1:
                fn.arity
            else:
                arity

        var op: OpCode = opNop

        if fn == ArrayF     : op = opArray
        elif fn == DictF    : op = opDict
        elif fn == FuncF    : op = opFunc
        elif fn == AddF     : op = opAdd
        elif fn == SubF     : op = opSub
        elif fn == MulF     : op = opMul
        elif fn == DivF     : op = opDiv
        elif fn == FdivF    : op = opFDiv
        elif fn == ModF     : op = opMod
        elif fn == PowF     : op = opPow
        elif fn == NegF     : op = opNeg
        elif fn == BNotF    : op = opBNot
        elif fn == BAndF    : op = opBAnd
        elif fn == BOrF     : op = opBOr
        elif fn == ShlF     : op = opShl
        elif fn == ShrF     : op = opShr
        elif fn == NotF     : op = opNot
        elif fn == AndF     : op = opAnd
        elif fn == OrF      : op = opOr
        elif fn == EqF      : op = opEq
        elif fn == NeF      : op = opNe
        elif fn == GtF      : op = opGt
        elif fn == GeF      : op = opGe
        elif fn == LtF      : op = opLt
        elif fn == LeF      : op = opLe
        elif fn == IfF      : callType = SpecialCall; op = opIf
        elif fn == IfEF     : callType = SpecialCall; op = opIfE
        elif fn == UnlessF  : callType = SpecialCall; op = opUnless
        elif fn == UnlessEF : callType = SpecialCall; op = opUnless
        elif fn == ElseF    : callType = SpecialCall; op = opElse
        elif fn == SwitchF  : callType = SpecialCall; op = opSwitch
        elif fn == WhileF   : callType = SpecialCall; op = opWhile
        elif fn == ReturnF  : op = opReturn
        elif fn == ToF      : op = opTo
        elif fn == PrintF   : op = opPrint
        elif fn == GetF     : op = opGet
        elif fn == SetF     : op = opSet
        elif fn == RangeF   : op = opRange
        elif fn == LoopF    : op = opLoop
        elif fn == MapF     : op = opMap
        elif fn == SelectF  : op = opSelect
        elif fn == SizeF    : op = opSize
        elif fn == ReplaceF : op = opReplace
        elif fn == SplitF   : op = opSplit
        elif fn == JoinF    : op = opJoin
        elif fn == ReverseF : op = opReverse
        elif fn == IncF     : op = opInc
        elif fn == DecF     : op = opDec

        if callType == OtherCall and op != opNop:
            callType = BuiltinCall

        var v: Value =
            if callType == OtherCall: 
                newWord(name)
            else:
                nil

        target.addChild(newCallNode(callType, ar, v, op))
        
        target.rollThrough()

    func addStore(target: var Node, val: Value) {.enforceNoRaises.} =
        target.addChild(newCallNode(VariableStore, 1, val))

        target.rollThrough()

    proc addAttribute(target: var Node, val: Value, isLabel: static bool = false) {.enforceNoRaises.} =
        let attrNode = newCallNode(AttributeNode, 1, val)

        when not isLabel:
            attrNode.addChild(newConstant(VTRUE))

        target.addChild(attrNode)

        when isLabel:
            target.rollThrough()

    template addPotentialInfixCall(target: var Node): untyped =
        if i < nLen - 1:
            let nextNode {.cursor.} = blok.a[i+1]
            if nextNode.kind == Symbol and nextNode.m notin {arrowright, thickarrowright, pipe}:
                if (let aliased = Aliases.getOrDefault(nextNode.m, NoAliasBinding); aliased != NoAliasBinding):
                    var symfunc {.cursor.} = GetSym(aliased.name.s)

                    if symfunc.kind==Function and aliased.precedence==InfixPrecedence:
                        when processingArrow:
                            ArrowBlock.add(nextNode)
                        i += 1
                        target.addCall(aliased.name.s, fun=symfunc)

    proc addTerminal(target: var Node, node: Node) =
        with target:
            rewindCallBranches()

            addPotentialInfixCall()

            addChild(node)

            rewindCallBranches(optimize=true)

    proc addPath(target: var Node, val: Value, isLabel: static bool=false) =
        var pathCallV: Value = nil

        when not isLabel:
            if (let curr = Syms.getOrDefault(val.p[0].s, nil); not curr.isNil):
                let next {.cursor.} = val.p[1]
                if curr.kind==Dictionary and (next.kind==Literal or next.kind==Word):
                    if (let item = curr.d.getOrDefault(next.s, nil); not item.isNil):
                        if item.kind == Function:
                            pathCallV = item

        if not pathCallV.isNil:
            target.addChild(Node(kind: OtherCall, arity: pathCallV.arity, op: opNop, value: pathCallV))
            target.rollThrough()
        else:
            let basePath {.cursor.} = val.p[0]

            when isLabel:
                var baseNode = newVariable(basePath)
            else:
                var baseNode = 
                    if TmpArities.getOrDefault(basePath.s, -1) == 0:
                        newCallNode(OtherCall, 0, basePath)
                    else:
                        newVariable(basePath)

            var i = 1

            while i < val.p.len:
                when isLabel:
                    let newNode = 
                        if i == val.p.len - 1:
                            newCallNode(BuiltinCall, 3, nil, opSet)
                        else:
                            newCallNode(BuiltinCall, 2, nil, opGet)
                else:
                    let newNode = newCallNode(BuiltinCall, 2, nil, opGet)
                
                newNode.addChild(baseNode)
                
                if val.p[i].kind==Block:
                    var subNode = newRootNode()
                    discard subNode.processBlock(val.p[i])
                    newNode.addChildren(subNode.children)
                else:
                    newNode.addChild(newConstant(val.p[i]))
                
                baseNode = newNode
                i += 1

            when isLabel:
                target.addChild(baseNode)
                target.rollThrough()
            else:
                target.addTerminal(baseNode)

    template addPotentialTrailingPipe(target: var Node): untyped =
        var added = false
        if i < nLen - 1:
            var nextNode {.cursor.} = blok.a[i+1]
            if nextNode.kind == Word:
                if (let funcArity = TmpArities.getOrDefault(nextNode.s, -1); funcArity != -1):
                    i += 1
                    target.rewindCallBranches()

                    var lastChild = target.children[^1]
                    if lastChild.kind == VariableStore:
                        lastChild = lastChild.children[^1]
                        target = lastChild.parent   
                    
                    target.children.delete(target.children.len-1)

                    target.addCall(nextNode.s, funcArity)
                    target.addChild(lastChild)

                    target.rewindCallBranches()
                    
                    added = true

        if not added:
            target.addTerminal(newConstant(newSymbol(pipe)))

    proc addInline(target: var Node, val: Value) =
        var subNode = newRootNode()
        discard subNode.processBlock(val)

        with target:
            rewindCallBranches()

            addPotentialInfixCall()

            addChildren(subNode.children)
            
            rewindCallBranches()

    proc addArrowBlock(target: var Node, val: Value) =
        var subNode = newRootNode()
        i = subNode.processBlock(val, start=i+1, processingArrow=true)

        target.addTerminal(newConstant(newBlock(ArrowBlock)))

        ArrowBlock.setLen(0)

    proc addThickArrowBlocks(target: var Node) =
        # get next node
        let subnode {.cursor.} = blok.a[i+1]

        # we'll want to create the two blocks, 
        # for functions like loop, map, select, filter
        # so let's get them ready
        var argblock, subblock: ValueArray

        # if it's a word
        if subnode.kind==Word:
            subblock = @[subnode]
            # check if it's a function
            if (let funcArity = TmpArities.getOrDefault(subnode.s, -1); funcArity != -1):
                # automatically "push" all its required arguments
                for j in 0..(funcArity-1):
                    let arg = newWord("_" & $(j))
                    argblock.add(arg)
                    subblock.add(arg)

        elif subnode.kind==Block:
            # replace ampersand symbols, 
            # sequentially, with arguments
            var idx = 0
            var fnd: int8 = 0
            while idx<subnode.a.len:
                if (subnode.a[idx]).isSymbol(ampersand):
                    let arg = newWord("_" & $(fnd))
                    argblock.add(arg)
                    subblock.add(arg)
                else:
                    subblock.add(subnode.a[idx])
                idx += 1

        if argblock.len == 1:
            target.addTerminal(newConstant(newLiteral(argblock[0].s)))
        else:
            target.addTerminal(newConstant(newBlock(argblock)))

        target.addTerminal(newConstant(newBlock(subblock)))

    #------------------------
    # The Main Loop
    #------------------------

    while i < nLen:
        let item = blok.a[i]

        when processingArrow:
            ArrowBlock.add(item)

        case item.kind:
            of Word:
                var funcArity = TmpArities.getOrDefault(item.s, -1)
                if funcArity != -1:
                    current.addCall(item.s, funcArity)
                else:
                    if item.s == "true":
                        current.addTerminal(newConstant(VTRUE))
                    elif item.s == "false":
                        current.addTerminal(newConstant(VFALSE))
                    else:
                        current.addTerminal(newVariable(item))

            of Label:
                current.addStore(item)

            of Attribute:
                current.addAttribute(item)

            of AttributeLabel:
                current.addAttribute(item, isLabel=true)

            of Path:
                current.addPath(item)

            of PathLabel:
                current.addPath(item, isLabel=true)

            of Inline:
                current.addInline(item)

            of Symbol:
                case item.m:
                    of doublecolon      :
                        inc(i)
                        var subblock: ValueArray
                        while i < nLen:
                            subblock.add(blok.a[i])
                            inc(i)
                        
                        current.addTerminal(newConstant(newBlock(subblock)))
                            
                    of arrowright       : 
                        current.addArrowBlock(blok)

                    of thickarrowright  :
                        current.addThickArrowBlocks()

                    of pipe             :
                        current.addPotentialTrailingPipe()

                    else:
                        let symalias = item.m
                        let aliased = Aliases.getOrDefault(symalias, NoAliasBinding)
                        if likely(aliased != NoAliasBinding):
                            var symfunc {.cursor.} = GetSym(aliased.name.s)
                            if symfunc.kind==Function:
                                current.addCall(aliased.name.s, fun=symfunc)
                            else: 
                                if aliased.name.s == "null":
                                    current.addTerminal(newConstant(VNULL))
                                else:
                                    current.addTerminal(newVariable(newWord(aliased.name.s)))
                        else:
                            current.addTerminal(newConstant(item))

            of Newline:
                discard

            else:
                current.addTerminal(newConstant(item))

        i += 1

        when processingArrow:
            if current.kind == RootNode:
                break

    return i-1
    
#=======================================
# Output
#=======================================

proc dumpNode*(node: Node, level = 0, single: static bool = false): string =
    template indentNode(): untyped =
        result &= "     ".repeat(level)

    case node.kind:
        of RootNode:
            indentNode()
            result &= "ROOT: \n"
            for child in node.children:
                result &= dumpNode(child, level+1)
        of TerminalNode:
            indentNode()
            result &= "Constant: " & $(node.value)

        of CallNode:
            indentNode()
            if node.kind == VariableStore:
                result &= "Store: " & $(node.value) & "\n"
            else:
                result &= "Call: "
                if node.value.isNil:
                    result &= ($node.op).replace("op","").toLowerAscii() & " <" & $node.arity & ">\n"
                else:
                    result &= node.value.s & " <" & $node.arity & ">\n"

            when not single:
                for child in node.children:
                    result &= dumpNode(child, level+1)

    result &= "\n"

#=======================================
# Main
#=======================================

proc generateAst*(parsed: Value): Node =
    result = newRootNode()

    TmpArities = collect:
        for k,v in Syms.pairs:
            if v.kind == Function:
                {k: v.arity}

    discard result.processBlock(parsed)

    echo dumpNode(result)

    # echo "TRAVERSING"

    # for node in traverseTree(result):
    #     echo dumpNode(node, single=true)

    # echo "FINISHED"