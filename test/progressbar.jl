using Progbiotic

duration_str(1)
duration_str(10)
duration_str(100)
duration_str(1000)
duration_str(10000)
duration_str(100000)
duration_str(1000000)

p = ProgJob("foobar")

show_progjob_with_theme(p, AMBER) |> println

with_job(1:100) do x
    sleep(0.1)
end


# 1. Simple range with default theme
for i in ProgJob(1:50; desc = "Downloading")
    sleep(0.04)
end

# 2. Vector with custom theme (e.g. OCEAN or CYBERPUNK)
files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
for file in ProgJob(files, OCEAN; desc = "Parsing files")
    sleep(0.3)
end

# 3. Works seamlessly with comprehensions / map / collect
[x^2 for x in ProgJob(1:3000000000, GLACIER; desc = "Squaring")];

p = ProgJob(1:100, AMBER; desc = "Test")
for i in p
    sleep(0.05)
end

p = ProgJob(1:100; desc = "Test")
@threads for i in p
    sleep(0.1)
end

[x^2 for x in ProgJob(rand(32,32), GLACIER; desc = "Squaring matrix elements!")]

