#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2023 Yanis Zafirópulos
#
# @file: library/Quantities.nim
#=======================================================

## The main Quantities module 
## (part of the standard library)

#=======================================
# Pragmas
#=======================================

{.used.}

#=======================================
# Libraries
#=======================================

import vm/values/custom/vquantity
import vm/values/custom/quantities/preprocessor

when not defined(NOGMP):
    import helpers/bignums as BignumsHelper

import vm/lib

#=======================================
# Helpers
#=======================================

template convertQuantity(x, y: Value, xKind, yKind: ValueKind): untyped =
    let qs = 
        if x.kind == Unit:
            x.u
        else:
            parseAtoms(x.s)

    if yKind==Quantity:
        push newQuantity(y.q.convertQuantity(qs))
    elif yKind==Integer:
        if y.iKind == NormalInteger:
            push newQuantity(toQuantity(y.i, qs))
        else:
            when not defined(NOGMP):
                push newQuantity(toQuantity(y.bi, qs))
    elif yKind==Floating:
        push newQuantity(toQuantity(y.f, qs))
    else:
        push newQuantity(toQuantity(y.rat, qs))

#=======================================
# Methods
#=======================================

proc defineSymbols*() =

    addPhysicalConstants()
    addPropertyPredicates()

    builtin "conforms?",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "check if given quantities/units are compatible",
        args        = {
            "a"     : {Quantity, Unit},
            "b"     : {Quantity, Unit}
        },
        attrs       = NoAttrs,
        returns     = {Logical},
        example     = """
            conforms? 3`m `m                ; => true
            conforms? 4`m `cm               ; => true

            conforms? 5`m `s                ; => false
            ..........
            givenValue: 6`yd/s      

            conforms? givenValue `m         ; => false
            conforms? givenValue `km/h      ; => true
            ..........
            conforms? 3`m 4`m               ; => true
            conforms? 5`W 5`N               ; => false
            conforms? 5`W 3`J/s             ; => true
        """:
            #=======================================================
            if xKind == Quantity:
                if yKind == Quantity:
                    push newLogical(x.q =~ y.q)
                else:
                    push newLogical(x.q =~ y.u)
            else:
                if yKind == Quantity:
                    push newLogical(x.u =~ y.q)
                else:
                    push newLogical(x.u =~ y.u)

    builtin "convert",
        alias       = longarrowright,
        op          = opNop,
        rule        = InfixPrecedence,
        description = "convert quantity to given unit",
        args        = {
            "value" : {Quantity,Integer,Floating,Rational},
            "unit"  : {Unit,Literal,String,Word}
        },
        attrs       = NoAttrs,
        returns     = {Quantity},
        example     = """
            print convert 3`m `cm
            ; 300.0 cm

            print 1`yd2 --> `m2
            ; 0.836127 m²
        """:
            #=======================================================
            convertQuantity(y, x, yKind, xKind)

    builtin "in",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "convert quantity to given unit",
        args        = {
            "unit"  : {Unit,Literal,String,Word},
            "value" : {Quantity,Integer,Floating,Rational}
        },
        attrs       = NoAttrs,
        returns     = {Quantity},
        example     = """
            print in`cm 3`m
            ; 300.0 cm

            print in`m2 1`yd2
            ; 0.836127 m²
        """:
            #=======================================================
            convertQuantity(x, y, xKind, yKind)

    builtin "property",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "get the described property of given quantity or unit",
        args        = {
            "quantity"  : {Quantity, Unit}
        },
        attrs       = {
            "hash"  : ({Logical}, "get property as a hash")
        },
        returns     = {Literal, Integer},
        example     = """
            property 3`m            ; => 'length
            property 4`m2           ; => 'area
            property 5`m3           ; => 'volume

            property 6`J/s          ; => 'power
            property 3`V            ; => 'potential
        """:
            #=======================================================
            if xKind == Quantity:
                if hadAttr("hash"):
                    push newInteger(x.q.signature)
                else:
                    push newLiteral(getProperty(x.q))
            else:
                if hadAttr("hash"):
                    push newInteger(getSignature(x.u))
                else:
                    push newLiteral(getProperty(x.u))

    builtin "scalar",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "get quantity value in the appropriate numeric type",
        args        = {
            "value"     : {Quantity}
        },
        attrs       = NoAttrs,
        returns     = {Integer, Floating, Rational},
        example     = """
            scalar 3`m              ; => 3
            scalar 4.0`m2           ; => 4
            scalar 10:2`m3          ; => 5
            ..........
            scalar 3.1`m            ; => 3.1
            scalar 5:2`m            ; => 2.5    
            ..........
            scalar 13:3`m           ; => 13/3
        """:
            #=======================================================
            let r {.cursor.} = x.q.original

            if r.rKind == NormalRational:
                if r.den == 1:
                    push(newInteger(r.num))
                elif r.canBeCoerced():
                    push(newFloating(toFloat(r)))
                else:
                    push(newRational(r))
            else:
                when not defined(NOGMP):
                    if r.br.denominator() == 1:
                        push(newInteger(r.br.numerator()))
                    elif r.canBeCoerced():
                        push(newFloating(toFloat(r)))
                    else:
                        push(newRational(r))

    builtin "specify",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "define new user unit",
        args        = {
            "name"  : {Literal,String},
            "value" : {Quantity,Unit}
        },
        attrs       = {
            "symbol"    : ({String}, "define main unit symbol"),
            "describes" : ({String}, "set corresponding property for new unit"),
            "property"  : ({Logical}, "define a new property")
        },
        returns     = {Literal},
        example     = """
            specify 'nauMile 1.1508`mi

            print 2`nauMile                ; 2 nauMile
            print 3`nauMile --> `km        ; 5.5560992256 km
            ..........
            specify.symbol:"NM" 'nauMile 1.1508`mi

            print 2`nauMile                ; 2 NM
            ..........
            specify.describes:"coding speed" 'lph `lines/h

            print 100`lph                   ; 100 lph
            print property 100`lph          ; coding speed
            ..........
            specify.property "sweetness" `tspSugar

            print property 3`tspSugar       ; sweetness
        """:
            #=======================================================
            if hadAttr("property"):
                if yKind == Quantity:
                    defineNewProperty(x.s, y.q)
                else:
                    defineNewProperty(x.s, y.u)
            else:
                var sym = x.s
                var desc = x.s
 
                if checkAttr("symbol"):
                    sym = aSymbol.s
 
                if checkAttr("describes"):
                    desc = aDescribes.s
 
                if yKind == Quantity:
                    defineNewUserUnit(x.s, sym, desc, y.q)
                else:
                    defineNewUserUnit(x.s, sym, desc, y.u)

    builtin "units",
        alias       = unaliased,
        op          = opNop,
        rule        = PrefixPrecedence,
        description = "get the unit of given quantity",
        args        = {
            "value"     : {Quantity}
        },
        attrs       = {
            "base"  : ({Logical}, "get base units")
        },
        returns     = {Unit},
        # TODO(Quantities/unit) add documentation example
        #  labels: documentation, easy
        example     = """
        """:
            #=======================================================
            if hadAttr("base"):
                push newUnit(getBaseUnits(x.q))
            else:
                push(newUnit(x.q.atoms))

#=======================================
# Add Library
#=======================================

Libraries.add(defineSymbols)
