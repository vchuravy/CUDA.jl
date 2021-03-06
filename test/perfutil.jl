PERFORMANCE = haskey(ENV, "PERFORMANCE")
CODESPEED = get(ENV, "CODESPEED", nothing)
if CODESPEED != nothing && !PERFORMANCE
    error("Cannot submit to Codespeed without enabling performance measurements")
end

if CODESPEED != nothing
    using JSON
    using HTTPClient.HTTPC

    # Setup codespeed data dict for submissions to codespeed's JSON endpoint.  These parameters
    # are constant across all benchmarks, so we'll just let them sit here for now
    pkgdir = dirname(Base.source_path())
    csdata = Dict()
    csdata["commitid"] = chomp(readall(`git -C $pkgdir rev-parse HEAD`))
    csdata["project"] = "CUDA.jl"
    csdata["branch"] = chomp(readall(`git -C $pkgdir symbolic-ref -q --short HEAD`))
    csdata["executable"] = CUDA_VENDOR
    csdata["environment"] = chomp(readall(`hostname`))
    csdata["result_date"] = chomp(readall(`date +'%Y-%m-%d %H:%M:%S'`))
    csdata["revision_date"] = join(split(
            chomp(readall(`git -C $pkgdir log --pretty=format:%cd -n 1 --date=iso`)
        ))[1:2], " " )    # ISO date format minus the timezone
end

# Takes in the raw array of values in vals, along with the benchmark name, description, unit and whether less is better
function submit_to_codespeed(vals,name,desc,unit,test_group,lessisbetter=true)
    csdata["benchmark"] = name
    csdata["description"] = desc
    csdata["result_value"] = mean(vals)
    csdata["std_dev"] = std(vals)
    csdata["min"] = minimum(vals)
    csdata["max"] = maximum(vals)
    csdata["units"] = unit
    csdata["units_title"] = test_group
    csdata["lessisbetter"] = lessisbetter

    println( "$name: $(mean(vals))" )
    ret = post( "http://$CODESPEED/result/add/json/", Dict("json" => json([csdata])) )
    println( json([csdata]) )
    if ret.http_code != 200 && ret.http_code != 202
        error("could not submit $name [HTTP code $(ret.http_code)]")
    end
end

function readable(d)
    if d > 60
        error("unimplemented")
    elseif d < 1
        t = ["m", "µ", "n", "p"]
        for i in 1:length(t)
            scale = 10.0^-3i
            if scale < d <= scale*1000
                return "$(signif(d/scale, 2)) $(t[i])s"
            end
        end
        error()
    else
        return "$(round(d, 2)) s"
    end
end

macro output_timings(t,name,desc,group)
    if CODESPEED == nothing
        ex = quote
            @printf "%-20s: %s ± %s\n" $name readable(mean($t)) readable(std($t))
        end
    else
        ex = quote
            # If we weren't given anything for the test group, infer off of file path!
            test_group = length($group) == 0 ? basename(dirname(Base.source_path())) : $group[1]

            submit_to_codespeed($t, $name, $desc, "seconds", test_group)
        end
    end

    ex
end

const mintrials = 5
const maxtime = 2.5       # in seconds

# TODO: wrap in let -- end?
# TODO: trials shouldn't be accessible afterwards
macro timeit(setup,ex,verification,teardown,name,desc,group...)
    quote
        trials = $mintrials
        t = zeros(trials)

        # warm up and verify
        let
            $(esc(setup))
            e = @elapsed $(esc(ex))
            $(esc(verification))
            $(esc(teardown))
        end
        e = @elapsed ()

        # benchmark
        # TODO: compile-time branch?
        if PERFORMANCE
            i = 1
            start = time()
            while i <= trials
                let
                    $(esc(setup))
                    gc_disable()
                    e = @elapsed $(esc(ex))
                    gc_enable()
                    $(esc(teardown))
                end

                t[i] = e
                if i == trials && (time()-start) < $maxtime
                    # check if accurate enough
                    uncertainty = std(t[1:i])/mean(t[1:i])
                    if uncertainty > .05
                        trials *= 2
                        resize!(t, trials)
                    end
                end

                i += 1
            end
            @output_timings t $name $desc $group
        end
    end
end


# seed rng for more consistent timings
srand(1776)
