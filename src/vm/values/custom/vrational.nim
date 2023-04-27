#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2023 Yanis Zafirópulos
#
# @file: vm/values/custom/vrational.nim
#=======================================================

## The internal `:rational` type

# Contains code based on
# the Rationals module: https://raw.githubusercontent.com/nim-lang/Nim/version-1-6/lib/pure/rationals.nim
# which forms part of the Nim standard library.
# (c) Copyright 2015 Dennis Felsing

#=======================================
# Libraries
#=======================================

import hashes, math, strformat

when not defined(NOGMP):
    import helpers/bignums

import helpers/intrinsics

#=======================================
# Types
#=======================================

type 
    RationalKind* = enum
        NormalRational,
        BigRational

    VRational* = object
        case rKind*: RationalKind:
            of NormalRational:
                num*: int
                den*: int
            of BigRational:
                when not defined(NOGMP):
                    br*: Rat

#=======================================
# Forward declarations
#=======================================

func toRational*(num, den: int): VRational

#=======================================
# Helpers
#=======================================

template safeOp(op: untyped): untyped =
    if op:
        raise newException(ValueError, "OVERFLOW!")

func reduce(x: var VRational) =
    let common = gcd(x.num, x.den)
    if x.den > 0:
        x.num = x.num div common
        x.den = x.den div common
    elif x.den < 0:
        x.num = -x.num div common
        x.den = -x.den div common
    else:
        raise newException(DivByZeroDefect, "division by zero")

func simplifyRational*(x: var VRational) =
    when not defined(NOGMP):
        if x.rKind == BigRational and canBeSimplified(x.br):
            x = toRational(getInt(numerator(x.br)), getInt(denominator(x.br)))

#=======================================
# Templates
#=======================================

template getNumerator*(x: VRational, big: bool = false): untyped =
    when big and not defined(NOGMP):
        numerator(x.br)
    else:
        x.num

template getDenominator*(x: VRational, big: bool = false): untyped =
    when big and not defined(NOGMP):
        denominator(x.br)
    else:
        x.den

#=======================================
# Methods
#=======================================

func toRational*(num, den: int): VRational =
    # create VRational from numerator and denominator (both int's)
    result.rKind = NormalRational
    result.num = num
    result.den = den
    reduce(result)

func `//`*(num, den: int): VRational =
    toRational(num, den)

when not defined(NOGMP):
    func initRational*(num: Int, den: Int): VRational =
        result.rKind = BigRational
        result.br = newRat(num, den)

        simplifyRational(result)

    func initRational*(num: int, den: Int): VRational =
        result.rKind = BigRational
        result.br = newRat(newInt(num), den)
        
        simplifyRational(result)

    func initRational*(num: Int, den: int): VRational =
        result.rKind = BigRational
        result.br = newRat(num, newInt(den))

        simplifyRational(result)

func toRational*(x: int): VRational =
    result.rKind = NormalRational
    result.num = x
    result.den = 1

when not defined(NOGMP):
    func toRational*(x: Int): VRational = 
        result.rKind = BigRational
        result.br = newRat(x)

    func toBigRational*(x: int | Int | float): VRational =
        result.rKind = BigRational
        result.br = newRat(x)
        
        simplifyRational(result)

    func toBigRational*(x: VRational): VRational =
        if x.rKind == BigRational:
            result = x
        else:
            result.rKind = BigRational
            result.br = newRat(x.num, x.den)

func toRational*(x: float, n: int = high(int) shr (sizeof(int) div 2 * 8)): VRational =
    var
        m11, m22 = 1
        m12, m21 = 0
        ai = int(x)
        initial = x
        x = x
    while m21 * ai + m22 <= n:
        swap m12, m11
        swap m22, m21
        m11 = m12 * ai + m11
        m21 = m22 * ai + m21
        if x == float(ai): 
            break # division by zero
        x = 1 / (x - float(ai))
        if x > float(high(int32)): 
            when not defined(NOGMP):
                if m11 == 0 or m21 == 0: 
                    return toBigRational(initial)
                else: 
                    break
            else:
                break # representation failure; should throw error?
        ai = int(x)
    result = m11 // m21

func toFloat*(x: VRational): float =
    if x.rKind == NormalRational:
        result = x.num / x.den
    else:
        when not defined(NOGMP):
            result = toCDouble(x.br)

func toInt*(x: VRational): int =
    if x.rKind == NormalRational:
        result = x.num div x.den
    else:
        discard
        # show error

func `+`*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                let common = lcm(x.den, y.den)
                result.rKind = NormalRational
                let part1 = common div x.den * x.num
                let part2 = common div y.den * y.num
                safeOp: addIntWithOverflow(part1, part2, result.num)
                #result.num = common div x.den * x.num + common div y.den * y.num
                result.den = common
                reduce(result)
            except CatchableError:
                when not defined(NOGMP):
                    result = toBigRational(x) + y
        else:
            when not defined(NOGMP):
                result = x + toBigRational(y)
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = toBigRational(x) + y
            else:
                result = VRational(
                    rKind: BigRational,
                    br: x.br + y.br
                )

func `+`*(x: VRational, y: int): VRational =
    if x.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            var m: int
            safeOp: mulIntWithOverflow(x.den, y, m)
            safeOp: addIntWithOverflow(x.num, m, result.num)
            #result.num = x.num + y * x.den
            result.den = x.den
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) + y
    else:
        when not defined(NOGMP):
            result = x + toBigRational(y)

func `+`*(x: int, y: VRational): VRational =
    if y.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            var m: int
            safeOp: mulIntWithOverflow(y.den, x, m)
            safeOp: addIntWithOverflow(y.num, m, result.num)
            #result.num = y.num + x * y.den
            result.den = y.den
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) + y
    else:
        when not defined(NOGMP):
            result = toBigRational(x) + y

func `+=`*(x: var VRational, y: VRational) =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                let common = lcm(x.den, y.den)
                let partOne = common div x.den * x.num
                let partTwo = common div y.den * y.num
                safeOp: addIntWithOverflow(partOne, partTwo, x.num)
                #x.num = common div x.den * x.num + common div y.den * y.num
                x.den = common
                reduce(x)
            except CatchableError:
                when not defined(NOGMP):
                    x = toBigRational(x) + y
        else:
            when not defined(NOGMP):
                x = toBigRational(x) + y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                x += toBigRational(y)
            else:
                x.br += y.br

func `+=`*(x: var VRational, y: int) =
    if x.rKind == NormalRational:
        try:
            var m: int
            safeOp: mulIntWithOverflow(y, x.den, m)
            safeOp: addIntWithOverflow(x.num, m, x.num)
            #x.num += y * x.den
        except CatchableError:
            when not defined(NOGMP):
                x = toBigRational(x) + y
    else:
        when not defined(NOGMP):
            x += toBigRational(y)

func `-`*(x: VRational): VRational =
    if x.rKind == NormalRational:
        result.num = -x.num
        result.den = x.den
    else:
        when not defined(NOGMP):
            result.rKind = BigRational
            result.br = neg(x.br)

func `-`*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                let common = lcm(x.den, y.den)
                let part1 = common div x.den * x.num
                let part2 = common div y.den * y.num
                safeOp: subIntWithOverflow(part1, part2, result.num)
                #result.num = common div x.den * x.num - common div y.den * y.num
                result.den = common
                reduce(result)
            except CatchableError:
                when not defined(NOGMP):
                    result = toBigRational(x) - y
        else:
            when not defined(NOGMP):
                result = toBigRational(x) - y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x - toBigRational(y)
            else:
                result = VRational(
                    rKind: BigRational,
                    br: x.br - y.br
                )

func `-`*(x: VRational, y: int): VRational =
    if x.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            var m: int
            safeOp: mulIntWithOverflow(y, x.den, m)
            safeOp: subIntWithOverflow(x.num, m, result.num)
            #result.num = x.num - y * x.den
            result.den = x.den
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) - y
    else:
        when not defined(NOGMP):
            result = x - toBigRational(y)

func `-`*(x: int, y: VRational): VRational =
    if y.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            var m: int
            safeOp: mulIntWithOverflow(x, y.den, m)
            safeOp: subIntWithOverflow(m, y.num, result.num)
            #result.num = x * y.den - y.num
            result.den = y.den
        except CatchableError:
            when not defined(NOGMP):
                result = x - toBigRational(y)
    else:
        when not defined(NOGMP):
            result = toBigRational(x) - y

func `-=`*(x: var VRational, y: VRational) =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                let common = lcm(x.den, y.den)
                let partOne = common div x.den * x.num
                let partTwo = common div y.den * y.num
                safeOp: subIntWithOverflow(partOne, partTwo, x.num)
                #x.num = common div x.den * x.num - common div y.den * y.num
                x.den = common
                reduce(x)
            except CatchableError:
                when not defined(NOGMP):
                    x = toBigRational(x) - y
        else:
            when not defined(NOGMP):
                x = toBigRational(x) + y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                x += toBigRational(y)
            else:
                x.br -= y.br
    
func `-=`*(x: var VRational, y: int) =
    if x.rKind == NormalRational:
        try:
            var m: int
            safeOp: mulIntWithOverflow(y, x.den, m)
            safeOp: subIntWithOverflow(x.num, m, x.num)
            # x.num -= y * x.den
        except CatchableError:
            when not defined(NOGMP):
                x = toBigRational(x) - y
    else:
        when not defined(NOGMP):
            x -= toBigRational(y)

func `*`*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                result.rKind = NormalRational
                safeOp: mulIntWithOverflow(x.num, y.num, result.num)
                #result.num = x.num * y.num
                safeOp: mulIntWithOverflow(x.den, y.den, result.den)
                #result.den = x.den * y.den
                reduce(result)
            except CatchableError:
                when not defined(NOGMP):
                    result = toBigRational(x) * y
        else:
            when not defined(NOGMP):
                result = toBigRational(x) * y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x * toBigRational(y)
            else:
                result = VRational(
                    rKind: BigRational,
                    br: x.br * y.br
                )
    
func `*`*(x: VRational, y: int): VRational =
    if x.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            safeOp: mulIntWithOverflow(x.num, y, result.num)
            #result.num = x.num * y
            result.den = x.den
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) * y
    else:
        when not defined(NOGMP):
            result = x * toBigRational(y)

func `*`*(x: int, y: VRational): VRational =
    if y.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            safeOp: mulIntWithOverflow(x, y.num, result.num)
            #result.num = x * y.num
            result.den = y.den
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) * y
    else:
        when not defined(NOGMP):
            result = toBigRational(x) * y

func `*=`*(x: var VRational, y: VRational) =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                safeOp: mulIntWithOverflow(x.num, y.num, x.num)
                safeOp: mulIntWithOverflow(x.den, y.den, x.den)
                #x.num *= y.num
                #x.den *= y.den
                reduce(x)
            except CatchableError:
                when not defined(NOGMP):
                    x = toBigRational(x) * y
        else:
            when not defined(NOGMP):
                x = toBigRational(x) * y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                x *= toBigRational(y)
            else:
                x.br *= y.br

func `*=`*(x: var VRational, y: int) =
    if x.rKind == NormalRational:
        try:
            safeOp: mulIntWithOverflow(x.num, y, x.num)
            #x.num *= y
            reduce(x)
        except CatchableError:
            when not defined(NOGMP):
                x = toBigRational(x) * y
    else:
        when not defined(NOGMP):
            x *= toBigRational(y)

func reciprocal*(x: VRational): VRational =
    if x.rKind == NormalRational:
        result.rKind = NormalRational
        if x.num > 0:
            result.num = x.den
            result.den = x.num
        elif x.num < 0:
            result.num = -x.den
            result.den = -x.num
        else:
            raise newException(DivByZeroDefect, "division by zero")
    else:
        when not defined(NOGMP):
            result.rKind = BigRational
            result.br = inv(x.br)

func `/`*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                safeOp: mulIntWithOverflow(x.num, y.den, result.num)
                #result.num = x.num * y.den
                safeOp: mulIntWithOverflow(x.den, y.num, result.den)
                #result.den = x.den * y.num
                reduce(result)
            except CatchableError:
                when not defined(NOGMP):
                    result = toBigRational(x) / y
        else:
            when not defined(NOGMP):
                result = toBigRational(x) / y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x / toBigRational(y)
            else:
                result = VRational(
                    rKind: BigRational,
                    br: x.br / y.br
                )

func `/`*(x: VRational, y: int): VRational =
    if x.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            result.num = x.num
            safeOp: mulIntWithOverflow(x.den, y, result.den)
            #result.den = x.den * y
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) / y
    else:
        when not defined(NOGMP):
            result = x / toBigRational(y)

func `/`*(x: int, y: VRational): VRational =
    if y.rKind == NormalRational:
        try:
            result.rKind = NormalRational
            safeOp: mulIntWithOverflow(x, y.den, result.num)
            #result.num = x * y.den
            result.den = y.num
            reduce(result)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) / y
    else:
        when not defined(NOGMP):
            result = toBigRational(x) / y

func `/=`*(x: var VRational, y: VRational) =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            try:
                safeOp: mulIntWithOverflow(x.num, y.den, x.num)
                safeOp: mulIntWithOverflow(x.den, y.num, x.den)
                reduce(x)
            except CatchableError:
                when not defined(NOGMP):
                    x = toBigRational(x) / y
        else:
            when not defined(NOGMP):
                x = toBigRational(x) / y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                x /= toBigRational(y)
            else:
                x.br /= y.br

func `/=`*(x: var VRational, y: int) =
    if x.rKind == NormalRational:
        x.den *= y
        reduce(x)
    else:
        when not defined(NOGMP):
            x /= toBigRational(y)

func `^`*(x: VRational, y: int): VRational =
    if x.rKind == NormalRational:
        try:
            if y < 0:
                safeOp: powIntWithOverflow(x.den, -y, result.num)
                safeOp: powIntWithOverflow(x.num, -y, result.den)
            else:
                safeOp: powIntWithOverflow(x.num, y, result.num)
                safeOp: powIntWithOverflow(x.den, y, result.den)
        except CatchableError:
            when not defined(NOGMP):
                result = toBigRational(x) ^ y

    else:
        when not defined(NOGMP):
            result = VRational(
                rKind: BigRational,
                br: x.br ^ y
            )

func `^`*(x: VRational, y: float): VRational =
    if x.rKind == NormalRational:
        let res = pow(toFloat(x), y)
        result = toRational(res)
    else:
        when not defined(NOGMP):
            result = VRational(
                rKind: BigRational,
                br: x.br ^ y
            )

func cmp*(x, y: VRational): int =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = (x - y).num
        else:
            when not defined(NOGMP):
                result = cmp(toBigRational(x), y)
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = cmp(x, toBigRational(y))
            else:
                result = cmp(x.br, y.br)

func `<`*(x, y: VRational): bool =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = (x - y).num < 0
        else:
            when not defined(NOGMP):
                result = toBigRational(x) < y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x < toBigRational(y)
            else:
                result = x.br < y.br

func `<=`*(x, y: VRational): bool =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = (x - y).num <= 0
        else:
            when not defined(NOGMP):
                result = toBigRational(x) <= y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x <= toBigRational(y)
            else:
                result = x.br <= y.br

func `==`*(x, y: VRational): bool =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = (x - y).num == 0
        else:
            when not defined(NOGMP):
                result = toBigRational(x) == y
    else:
        when not defined(NOGMP):
            if y.rKind == NormalRational:
                result = x == toBigRational(y)
            else:
                result = x.br == y.br

func abs*(x: VRational): VRational =
    if x.rKind == NormalRational:
        result.rKind = NormalRational
        result.num = abs x.num
        result.den = abs x.den
    else:
        when not defined(NOGMP):
            result.rKind = BigRational
            result.br = abs(x.br)

func `div`*(x, y: VRational): int =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = x.num * y.den div y.num * x.den
        else:
            raise newException(DivByZeroDefect, "div not supported")
    else:
        raise newException(DivByZeroDefect, "div not supported")

func `mod`*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result.rKind = NormalRational
            result.num = (x.num * y.den) mod (y.num * x.den)
            result.den = x.den * y.den
            reduce(result)
        else:
            raise newException(DivByZeroDefect, "mod not supported")
    else:
        raise newException(DivByZeroDefect, "mod not supported")

func floorDiv*(x, y: VRational): int =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result = floorDiv(x.num * y.den, y.num * x.den)
        else:
            raise newException(DivByZeroDefect, "floorDiv not supported")
    else:
        raise newException(DivByZeroDefect, "floorDiv not supported")

func floorMod*(x, y: VRational): VRational =
    if x.rKind == NormalRational:
        if y.rKind == NormalRational:
            result.rKind = NormalRational
            result.num = floorMod(x.num * y.den, y.num * x.den)
            result.den = x.den * y.den
            reduce(result)
        else:
            raise newException(DivByZeroDefect, "floorMod not supported")
    else:
        raise newException(DivByZeroDefect, "floorMod not supported")

func isZero*(x: VRational): bool =
    if x.rKind == NormalRational:
        result = x.num == 0
    else:
        when not defined(NOGMP):
            result = numerator(x.br) == 0

func isNegative*(x: VRational): bool =
    if x.rKind == NormalRational:
        result = x.num < 0
    else:
        when not defined(NOGMP):
            result = numerator(x.br) < 0

func isPositive*(x: VRational): bool =
    if x.rKind == NormalRational:
        result = x.num > 0
    else:
        when not defined(NOGMP):
            result = numerator(x.br) > 0

func hash*(x: VRational): Hash =
    if x.rKind == NormalRational:
        var copy = x
        reduce(copy)

        var h: Hash = 0
        h = h !& hash(copy.num)
        h = h !& hash(copy.den)
        result = !$h
    else:
        when not defined(NOGMP):
            result = hash(x.br[])

func codify*(x: VRational): string =
    if x.rKind == NormalRational:
        if x.num < 0:
            result = fmt("to :rational @[neg {x.num * -1} {x.den}]")
        else:
            result = fmt("to :rational [{x.num} {x.den}]")
    else:
        when not defined(NOGMP):
            let num = numerator(x.br)
            let den = denominator(x.br)
            if num < 0:
                result = fmt("to :rational @[neg {num * -1} {den}]")
            else:
                result = fmt("to :rational [{num} {den}]")

func `$`*(x: VRational): string =
    if x.rKind == NormalRational:
        result = $x.num & "/" & $x.den
    else:
        when not defined(NOGMP):
            result = $x.br