export enum GridSizeError {
	InvalidCellSize,
}

export function gridSize(
	surfaceWidthPx: int32,
	surfaceHeightPx: int32,
	cellWidthPx: int32,
	cellHeightPx: int32,
): Result<[int32, int32], GridSizeError> {
	if (cellWidthPx <= 0 || cellHeightPx <= 0) {
		return Result.err(GridSizeError.InvalidCellSize);
	}
	const cols = surfaceWidthPx / cellWidthPx;
	const rows = surfaceHeightPx / cellHeightPx;
	return Result.ok([cols < 1 ? 1 : cols, rows < 1 ? 1 : rows]);
}

test "an exact surface divides into its grid" {
	const size = gridSize(800, 600, 8, 15);
	assert size.ok;
	if (size.ok) {
		assert size.value[0] == 100;
		assert size.value[1] == 40;
	}
}

test "a partial cell at the edge is floored away" {
	const size = gridSize(803, 601, 8, 15);
	assert size.ok;
	if (size.ok) {
		assert size.value[0] == 100;
		assert size.value[1] == 40;
	}
}

test "a surface smaller than one cell holds a single cell" {
	const size = gridSize(7, 3, 8, 15);
	assert size.ok;
	if (size.ok) {
		assert size.value[0] == 1;
		assert size.value[1] == 1;
	}
}

test "a non-positive cell size is an error" {
	const zeroWidth = gridSize(800, 600, 0, 15);
	assert !zeroWidth.ok;
	const negativeHeight = gridSize(800, 600, 8, -15);
	assert !negativeHeight.ok;
}
