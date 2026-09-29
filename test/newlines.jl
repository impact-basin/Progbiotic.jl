using Progbiotic

y, z = 0, 0
@progress "outer" for i=1:10
    @info "foobar" i y z
    @progress "inner" for j=1:i
        @info "baz" i j z
            @progress "qux" for k=1:j
                @info "qux" i j k
                sleep(0.1)
            end
        sleep(0.1)
    end
end
