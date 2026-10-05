#include <bits/stdc++.h>
int main() {
    const long long M = 1000000007;
    long long n, s = 0;
    std::cin >> n;
    for (long long i = 1; i <= n; ++i) s = (s + i * i) % M;
    std::cout << s << "\n";
}
