using FastRunningMedian, Test, DataStructures, JLD2
import Statistics

"""
    check_health(mf::MedianFilter)

Check that all pointers point at a thing that again points back at them. Also check that low_heap is smaller than high_heap. 

Debug Function for MedianFilter. 
"""
function check_health(mf::MedianFilter)
    for k in 1:length(mf.heap_pos)
        current_heap, current_heap_ind = mf.heap_pos[k]
        if current_heap == true
            a = mf.low_heap[current_heap_ind][2] - mf.heap_pos_offset
            # println(k, " ?= ", a)
            @assert k == a
        else
            a = mf.high_heap[current_heap_ind][2] - mf.heap_pos_offset
            # println(k, " ?= ", a)
            @assert k == a
        end
    end

    if length(mf) >= 2
        @assert first(mf.low_heap) <= first(mf.high_heap)
    end
end

println("running tests...")

@testset "FastRunningMedian Tests" begin

    @testset "Stateful API Tests" begin
        
        @testset "Grow and Shrink Fuzz" begin
            # load test cases
            @load "fixtures/grow_shrink.jld2" grow_shrink_fixtures

            function grow_and_shrink_test(values, expected_medians)
                N = length(values)
                mf = MedianFilter(values[1], N)
                check_health(mf)
                @assert median(mf) == expected_medians[1]
                #grow phase
                for i in 2:N
                    grow!(mf, values[i])
                    check_health(mf)
                    @assert median(mf) == expected_medians[i]
                end
                # shrink phase
                for i in N+1:2N-1
                    shrink!(mf)
                    check_health(mf)
                    @assert median(mf) == expected_medians[i]
                end
                @assert length(mf) == 1
            end
            
            for fixture in grow_shrink_fixtures
                grow_and_shrink_test(fixture...)
            end
        end
        
        @testset "Roll Fuzz" begin
            #load test cases
            @load "fixtures/roll.jld2" roll_fixtures

            function roll_test(initial_values, roll_values, expected_medians)
                window_size = length(initial_values)
                mf = MedianFilter(initial_values[1], window_size)
                for i in 2:window_size
                    grow!(mf, initial_values[i])
                end
                @assert length(mf) == window_size
                for i in 1:length(roll_values)
                    mf_median = roll!(mf, roll_values[i])
                    check_health(mf)
                    @assert mf_median == expected_medians[i]
                end
            end

            for fixture in roll_fixtures
                roll_test(fixture...)
            end
        end

        @testset "Roll does work with window size 1" begin
            mf = MedianFilter(1., 1)
            @test 2. == roll!(mf, 2.)
            @test 1. == roll!(mf, 1.)
        end
    
        @testset "Grow! does not grow beyond capacity" begin
            mf = MedianFilter(1., 3)
            grow!(mf, 2.)
            grow!(mf, 3.)
            @test_throws ErrorException grow!(mf, 4.)
        end

        @testset "shrink! below 1-element errors" begin
            mf = MedianFilter(1., 4)
            @test_throws ErrorException shrink!(mf)
        end

        @testset "can only roll when capacity is exactly met" begin
            mf = MedianFilter(1., 3)
            grow!(mf, 2.)
            @test_throws ErrorException roll!(mf, 3.)
            grow!(mf, 3.)
            roll!(mf, 4.)
            shrink!(mf)
            @test_throws ErrorException roll!(mf, 5.)
        end


    end

    @testset "High Level API Tests" begin
        # Desired API
        # running_median(input::Array{T, 1}, window_size::Integer, tapering=:sym) where T <: Real
        # taperings:
        # :symmetric or :sym (window symmetric around returned point, length N-1 if even window, N if odd)
        # :asymmetric or :asym (window full length to one side, length length N+W-1 if odd W, N-1+W if even window)
        # :asymmetric_truncated or :asymtrunc (same as asymmetric, but truncated at ends to size of symmetric)
        # :none or :no (only full length window used, length N-W+1)
        # 
        # all these taperings are symmetrical in that they behave the same at each end of the array, only mirrored

        @testset "Basic API examples" begin
            @test_throws ErrorException running_median(zeros(0), 1)
            @test running_median([1.], 1) == [1.]
            @test running_median([1., 2., 3.], 1) == [1., 2., 3.]
            @test running_median([1., 4., 2., 1.], 3) == [1., 2., 2., 1.]
            @test running_median([1, 4, 2, 1], 3) == [1, 2, 2, 1]
            @test running_median([1, 4, 2, 1], 3, :asym) == [1, 2.5, 2, 2, 1.5, 1]
            @test running_median([1., 4., 2., 1.], 3, :sym) == [1., 2., 2., 1.]
            @test running_median([1., 4., 2., 1.], 3, :symmetric) == [1., 2., 2., 1.]
            @test running_median([1., 4., 2., 1.], 3, :asym) == [1., 2.5, 2., 2., 1.5, 1.]
            @test running_median([1., 4., 2., 1.], 3, :asymmetric) == [1., 2.5, 2., 2., 1.5, 1.]
            @test running_median([1., 4., 2., 1.], 3, :asym_trunc) == [2.5, 2., 2., 1.5]
            @test running_median([1., 4., 2., 1.], 3, :asymmetric_truncated) == [2.5, 2., 2., 1.5]
            @test running_median([1., 4., 2., 1.], 3, :no) == [2., 2.]
            @test running_median([1., 4., 2., 1.], 3, :none) == [2., 2.]
            @test running_median([1., 2., 1., 2., 1., 3.], 101) == [1., 1., 1., 2., 2., 3.]
            @test running_median([1., 1., 2., 1., 1., 1., 1., 1., 2., 1.], 99) == 
                [1., 1., 1., 1., 1., 1., 1., 1., 1., 1.]
        end

        
        @testset "compare to naive_symmetric_median" begin

            function naive_symmetric_median(arr, window)       
                output = similar(arr)
                offset = round((window - 1) / 2, Base.Rounding.RoundNearestTiesAway) |> Int
                for j in eachindex(arr)
                    temp_offset = min(offset, j - 1, length(arr) - j)
                    beginning = j - temp_offset
                    ending = j + temp_offset
                    to_median = arr[beginning:ending] |> skipmissing
                    output[j] = Statistics.median(to_median)
                end
                output
            end    
        
            function compare_to_naive(N, w)
                x = rand(N)
                y = running_median(x, w)
                y2 = naive_symmetric_median(x, w)
                @test y == y2
            end

    
            @testset "long input to test roll!" begin
                compare_to_naive(1_000_000, 101)
            end
    
            @testset "short input, long window" begin
                for i = 1:50
                    N = rand(3:20)
                    w = rand(19:2:100)
                    compare_to_naive(N, w)
                end
            end
    
            @testset "short windows" begin
                for i = 1:50
                    N = rand(10:1_000)
                    w = rand(3:2:11)
                    compare_to_naive(N, w)
                end
            end
    
            @testset "intermediate stuff" begin
                for i = 1:50
                    compare_to_naive(rand(100:10_000), rand(11:2:1_000))
                end
            end  
        end

        @testset "compare to naive_asymmetric_median" begin
            function naive_asymmetric_median(input, window_size)
                if window_size > length(input)
                    window_size = length(input)
                end
                growing_phase_inds = [1:k for k in 1:window_size]
                rolling_phase_inds = [k:k + window_size - 1 for k in 2:(length(input) - window_size + 1)]
                shrinking_phase_inds = [length(input) - k + 1:length(input) for k in window_size - 1:-1:1]
                phase_inds = [growing_phase_inds; rolling_phase_inds; shrinking_phase_inds]
                output = [Statistics.median(input[inds]) for inds in phase_inds]
                return output
            end

            for i in 1:100
                N = rand(1:50)
                w = rand(1:60)
                x = rand(Float64, N)
                @test naive_asymmetric_median(x, w) == running_median(x, w, :asym)
            end

            @testset "compare to naive_asymmetric_median with Ints" begin
                for i in 1:100
                    N = rand(1:50)
                    w = rand(1:60)
                    x = rand(Int, N)
                    @test naive_asymmetric_median(x, w) ≈ running_median(x, w, :asym)
                end
            end
        end

        @testset "compare to naive untapered median from RollingFunctions" begin
            using RollingFunctions
            for i in 1:100
                N = rand(1:50)
                w = rand(1:60)
                x = rand(N)
                if w > N
                    rf_w = N
                else
                    rf_w = w
                end
                @test rollmedian(x, rf_w) == running_median(x, w, :none)
            end
        end

        @testset "compare to naive_asymmetric_truncated_median" begin
            function naive_asymmetric_truncated_median(input, window_size)
                if window_size > length(input)
                    window_size = length(input)
                end

                if window_size |> iseven
                    alpha = (window_size / 2 + 1) |> Int
                else
                    alpha = ((window_size + 1) / 2) |> Int
                end
                growing_phase_inds = [1:k for k in alpha:window_size]
                rolling_phase_inds = [k:k + window_size - 1 for k in 2:(length(input) - window_size + 1)]
                shrinking_phase_inds = [length(input) - k + 1:length(input) for k in window_size - 1:-1:alpha]
                phase_inds = [growing_phase_inds; rolling_phase_inds; shrinking_phase_inds]
                output = [Statistics.median(input[inds]) for inds in phase_inds]
                return output
            end

            for i in 1:100
                N = rand(1:40)
                w = rand(1:50)
                x = rand(N)
                @test naive_asymmetric_truncated_median(x, w) == running_median(x, w, :asym_trunc)
            end
        end
        
    end
end # all tests