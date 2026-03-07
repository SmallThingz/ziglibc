#define expect(expr) ((void)((expr) || (on_expect_fail(#expr, __FILE__, __LINE__, __func__),0)))

#if defined(__GNUC__) || defined(__clang__)
__attribute__((__noreturn__))
#endif
void on_expect_fail(const char *expression, const char *file, int line, const char *func);
