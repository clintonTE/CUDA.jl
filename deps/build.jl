using CUDAapi
using CUDAdrv
using LLVM


## auxiliary routines

function build_error(reason)
    println("""
        $reason.

        This is not a fatal error, but GPU functionality will be unavailable.
        If you expected this to work, please open a thread on
        https://discourse.julialang.org/c/domain/gpu""")
    exit(1)
end

function llvm_support(version)
    @debug("Using LLVM $version")

    InitializeAllTargets()
    haskey(targets(), "nvptx") ||
        build_error("""
            Your LLVM does not support the NVPTX back-end.

            This is very strange; both the official binaries
            and an unmodified build should contain this back-end.""")

    target_support = sort(collect(CUDAapi.devices_for_llvm(version)))

    ptx_support = CUDAapi.isas_for_llvm(version)
    push!(ptx_support, v"6.0") # JuliaLang/julia#23817
    ptx_support = sort(collect(ptx_support))

    @debug("LLVM support", targets=target_support, isas=ptx_support)
    return target_support, ptx_support
end

function cuda_support(driver_version, toolkit_version)
    @debug("Using CUDA driver $driver_version and toolkit $toolkit_version")

    # the toolkit version as reported contains major.minor.patch,
    # but the version number returned by libcuda is only major.minor.
    toolkit_version = VersionNumber(toolkit_version.major, toolkit_version.minor)
    if toolkit_version > driver_version
        build_error("""
            CUDA $(toolkit_version.major).$(toolkit_version.minor) is not supported by
            your driver (which supports up to $(driver_version.major).$(driver_version.minor))""")
    end

    driver_target_support = CUDAapi.devices_for_cuda(driver_version)
    toolkit_target_support = CUDAapi.devices_for_cuda(toolkit_version)
    target_support = sort(collect(driver_target_support ∩ toolkit_target_support))

    driver_ptx_support = CUDAapi.isas_for_cuda(driver_version)
    toolkit_ptx_support = CUDAapi.isas_for_cuda(toolkit_version)
    ptx_support = sort(collect(driver_ptx_support ∩ toolkit_ptx_support))

    @debug("CUDA driver support", version=driver_version,
           targets=driver_target_support, isas=driver_ptx_support)
    @debug("CUDA toolkit support", version=toolkit_version,
           targets=toolkit_target_support, isas=toolkit_ptx_support)

    return target_support, ptx_support
end


## main

const config_path = joinpath(@__DIR__, "ext.jl")
const previous_config_path = config_path * ".bak"

function write_ext(config, path)
    open(path, "w") do io
        println(io, "# autogenerated file, do not edit")
        for (key,val) in config
            println(io, "const $key = $(repr(val))")
        end
    end
end

function read_ext(path)
    config = Dict{Symbol,Any}()
    r = r"^const (\w+) = (.+)$"
    open(path, "r") do io
        for line in eachline(io)
            m = match(r, line)
            if m != nothing
                config[Symbol(m.captures[1])] = eval(Meta.parse(m.captures[2]))
            end
        end
    end
    return config
end

function main()
    ispath(config_path) && mv(config_path, previous_config_path; force=true)
    config = Dict{Symbol,Any}(:configured => false)
    write_ext(config, config_path)


    ## gather info

    ### LLVM.jl

    LLVM.configured || build_error("Dependent package LLVM.jl has not been built successfully")

    LLVM.libllvm_system && build_error("CUDAnative.jl requires LLVM.jl to be built against Julia's LLVM library, not a system-provided one")

    llvm_version = LLVM.version()
    llvm_targets, llvm_isas = llvm_support(llvm_version)

    ### julia

    julia_llvm_version = Base.libllvm_version
    if julia_llvm_version != llvm_version
        build_error("LLVM $llvm_version incompatible with Julia's LLVM $julia_llvm_version")
    end

    ### CUDA

    CUDAdrv.configured || build_error("Dependent package CUDAdrv.jl has not been built successfully")

    toolkit_dirs = find_toolkit()
    cuda_toolkit_version = find_toolkit_version(toolkit_dirs)

    config[:cuda_driver_version] = CUDAdrv.version()
    cuda_targets, cuda_isas = cuda_support(config[:cuda_driver_version], cuda_toolkit_version)

    config[:target_support] = sort(collect(llvm_targets ∩ cuda_targets))
    isempty(config[:target_support]) && build_error("Your toolchain does not support any device target")

    config[:ptx_support] = sort(collect(llvm_isas ∩ cuda_isas))
    isempty(config[:target_support]) && build_error("Your toolchain does not support any PTX ISA")

    @debug("CUDAnative support", targets=config[:target_support], isas=config[:ptx_support])

    # discover other CUDA toolkit artifacts
    ## required
    config[:libdevice] = find_libdevice(config[:target_support], toolkit_dirs)
    config[:libdevice] == nothing && build_error("Available CUDA toolchain does not provide libdevice")
    ## optional
    config[:cuobjdump] = find_cuda_binary("cuobjdump", toolkit_dirs)
    config[:nvdisasm] = find_cuda_binary("nvdiasm", toolkit_dirs)
    config[:ptxas] = find_cuda_binary("ptxas", toolkit_dirs)

    config[:configured] = true


    ## (re)generate ext.jl

    if isfile(previous_config_path)
        previous_config = read_ext(previous_config_path)

        if config == previous_config
            mv(previous_config_path, config_path; force=true)
            return
        end
    end

    write_ext(config, config_path)

    return
end

main()
