using Progbiotic


@progress "Downloading weights" threads=true for i in 1:100
    sleep(0.01)
end

@progress "Long job!" threads=true for i in 1:30
    @progress "Short job $(i)!" vanish_timeout=2.0 for j in 1:10
        sleep(1)
    end
end
