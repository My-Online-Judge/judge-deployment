n = int(input())
M = 1000000007
s = 0
for i in range(1, n + 1):
    s = (s + i * i) % M
print(s)
