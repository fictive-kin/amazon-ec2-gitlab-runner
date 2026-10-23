export const sumReducer = (previous: number, current : number) : number => {
    if (current) {
        return previous + current
    }
    return previous
}
