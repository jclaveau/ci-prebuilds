/* fmodf as libm-fmod-custom on the widened operands. Exact: a float
 * remainder is representable in float, so the narrowing cast rounds nothing. */
double fmod(double, double);
float fmodf(float x, float y) { return (float)fmod(x, y); }
