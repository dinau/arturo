#import std/logging
# var logger = newConsoleLogger()

proc distribute[T](container: seq[T], size: int): seq[seq[T]] =
    ## Distributes elements in subSequences of maximum `size`
    var
        count: int = 1
        current: seq[T] = @[]

    for element in container:
        current.add element
        if (count mod size == 0) or (count == container.len):
            result.add current
            current = @[]
        count.inc()


proc medianOfMedians*[T](container: seq[T], middle: int): T =
    ## medianOfMedians returns the smallest nth number of a container

    #[
        Steps:
            1. Divide the container into sublists of a maximum of length x,
            let's say... 5
            2. Sort each sublist and determine the median
            3. Use the same function recursively to determine the median of the set
            4. Use this median as pivot element
            5. Partition the elements into right, left
            6. Do this comparation:
                - if i = k -> x
                - if i < k -> recuse using A[1, ..., k-1, i]
                - if i > k -> recurse using A[k+1, ...,i], i-k]

        » Read more on: https://brilliant.org/wiki/median-finding-algorithm/
    ]#

    const tiny = 5
    var
        medians, left, right: seq[T]
        pivot: T

    for list in container.distribute(tiny):
        medians.add list.medianOfMedians(list.len div 2)

    if medians.len <= tiny:
        pivot = medians.sorted()[medians.len div 2]
    else:
        pivot = medians.medianOfMedians(medians.len div 2)

    for element in container:
        if element > pivot: right.add element
        elif element < pivot: left.add element

    if middle < left.len:
        return left.medianOfMedians(middle)
    elif middle > left.len:
        return right.medianOfMedians(middle - left.high)
    else:
        return pivot
