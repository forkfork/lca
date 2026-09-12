return function(value, minimum, maximum)
    if value < minimum then return maximum end
    if value > maximum then return minimum end
    return value
end
