# ProgBiotic

Really neat progress bars.

Some examples:

```julia
# tqdm-like!
for i in ProgJob(1:100; desc = "Ordinary")
    sleep(0.1)
end

# thread-safe!
@threads for i in ProgJob(1:100; desc = "Multithreaded")
    sleep(0.1)
end

# themeable!
files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
for file in ProgJob(files, OCEAN; desc = "Parsing files")
    sleep(0.3)
end

# works with comprehensions!
[x^2 for x in ProgJob(1:9001, GLACIER; desc = "Squaring")];

# comprehensions over matrices!
[x^2 for x in ProgJob(rand(32,32), GLACIER; desc = "Squaring matrix elements!")]
```

## TODO

- Trees of progress bars
- Macro interfaces.
