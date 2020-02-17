# discovering binary CUDA dependencies

using Pkg, Pkg.Artifacts
using Libdl


## global state

const toolkit_dirs = Ref{Vector{String}}()

"""
    prefix()

Returns the installation prefix directories of the CUDA toolkit in use.
"""
prefix() = toolkit_dirs[]

const toolkit_version = Ref{VersionNumber}()

"""
    version()

Returns the version of the CUDA toolkit in use.
"""
version() = toolkit_version[]

"""
    release()

Returns the CUDA release part of the version as returned by [`version`](@ref).
"""
release() = VersionNumber(toolkit_version[].major, toolkit_version[].minor)

# paths
const nvdisasm = Ref{String}("nvdisasm")
const libcupti = Ref{String}("cupti")
const libnvtx = Ref{String}("nvtx")
const libdevice = Ref{String}()
const libcudadevrt = Ref{String}()

# device compatibility
const target_support = Ref{Vector{VersionNumber}}()
const ptx_support = Ref{Vector{VersionNumber}}()


## discovery

# NOTE: we don't use autogenerated JLLs, because we have multiple artifacts and need to
#       decide at run time (i.e. not via package dependencies) which one to use.
const cuda_artifacts = Dict(
    v"10.2" => ()->artifact"CUDA10.2",
    v"10.1" => ()->artifact"CUDA10.1",
    v"10.0" => ()->artifact"CUDA10.0",
    v"9.2"  => ()->artifact"CUDA9.2",
    v"9.0"  => ()->artifact"CUDA9.0",
)

# try use CUDA from an artifact
function use_artifact_cuda()
    # select compatible artifacts
    if haskey(ENV, "JULIA_CUDA_VERSION")
        wanted_version = VersionNumber(ENV["JULIA_CUDA_VERSION"])
        filter!(((version,artifact),) -> version == wanted_version, cuda_artifacts)
    else
        driver_version = CUDAdrv.release()
        filter!(((version,artifact),) -> version <= driver_version, cuda_artifacts)
    end

    # download and install
    artifact = nothing
    release = nothing
    for version in sort(collect(keys(cuda_artifacts)); rev=true)
        try
            artifact = cuda_artifacts[version]()
            release = version
            break
        catch
        end
    end
    artifact == nothing && error("Could not find a compatible artifact.")

    # utilities to look up stuff in the artifact (at known locations, so not using CUDAapi)
    get_binary(name) = joinpath(artifact, "bin", Sys.iswindows() ? "$name.exe" : name)
    function get_library(name)
        filename = if Sys.iswindows()
            "$name.dll"
        elseif Sys.isapple()
            "lib$name.dylib"
        else
            "lib$name.so"
        end
        joinpath(artifact, Sys.iswindows() ? "bin" : "lib", filename)
    end
    get_static_library(name) = joinpath(artifact, "lib", Sys.iswindows() ? "$name.lib" : "lib$name.a")
    get_file(path) = joinpath(artifact, path)

    nvdisasm[] = get_binary("nvdisasm")
    @assert isfile(nvdisasm[])
    version = parse_toolkit_version(nvdisasm[])

    # Windows libraries are tagged with the CUDA release
    long = "$(release.major)$(release.minor)"
    short = release >= v"10.1" ? string(release.major) : long

    libcupti[] = get_library(Sys.iswindows() ? "cupti64_$long" : "cupti")
    Libdl.dlopen(libcupti[])
    libnvtx[] = get_library(Sys.iswindows() ? "nvToolsExt64_1" : "nvToolsExt")
    Libdl.dlopen(libnvtx[])

    libcudadevrt[] = get_static_library("cudadevrt")
    @assert isfile(libcudadevrt[])
    libdevice[] = get_file(joinpath("share", "libdevice", "libdevice.10.bc"))
    @assert isfile(libdevice[])

    return version, [artifact]
end

# try to use CUDA from a local installation
function use_local_cuda(; silent=false, verbose=false)
    dirs = find_toolkit()

    path = find_cuda_binary("nvdisasm")
    if path == nothing
        error("Your CUDA installation does not provide the nvdisasm binary")
    else
        nvdisasm[] = path
    end
    version = parse_toolkit_version(nvdisasm[])

    cupti_dirs = map(dir->joinpath(dir, "extras", "CUPTI"), dirs) |> x->filter(isdir,x)
    path = find_cuda_library("cupti", [dirs; cupti_dirs], [version])
    if path == nothing
        silent || @warn("Your CUDA installation does not provide the CUPTI library, CUDAnative.@code_sass will be unavailable")
    else
        libcupti[] = path
    end
    path = find_cuda_library("nvtx", dirs, [v"1"])
    if path== nothing
        silent || @warn("Your CUDA installation does not provide the NVTX library, CUDAnative.NVTX will be unavailable")
    else
        libnvtx[] = path
    end

    path = find_libcudadevrt(dirs)
    if path === nothing
        error("Your CUDA installation does not provide libcudadevrt")
    else
        libcudadevrt[] = path
    end
    path = find_libdevice(dirs)
    if path === nothing
        error("Your CUDA installation does not provide libdevice")
    else
        libdevice[] = path
    end

    return version, dirs
end

function __init_bindeps__(; silent=false, verbose=false)
    # LLVM

    llvm_version = LLVM.version()


    # Julia

    julia_llvm_version = Base.libllvm_version
    if julia_llvm_version != llvm_version
        error("LLVM $llvm_version incompatible with Julia's LLVM $julia_llvm_version")
    end

    if llvm_version >= v"8.0" #&& CUDAdrv.release() < v"10.2"
        # NOTE: corresponding functionality in irgen.jl
        @debug "Incompatibility detected between CUDA and LLVM 8.0+; disabling debug info emission for CUDA kernels"
    end


    # CUDA

    try
        parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true")) ||
            error("Use of CUDA artifacts not allowed by user")
        toolkit_version[], toolkit_dirs[] = use_artifact_cuda()
        @debug "Using CUDA $(toolkit_version[]) from an artifact at $(join(toolkit_dirs[], ", "))"
    catch ex
        @error "Could not use CUDA from artifacts" exception=(ex, catch_backtrace())
        toolkit_version[], toolkit_dirs[] = use_local_cuda(silent=silent, verbose=verbose)
        @debug "Using local CUDA $(toolkit_version[]) at $(join(toolkit_dirs[], ", "))"
    end

    if release() < v"9"
        silent || @warn "CUDAnative.jl only supports CUDA 9.0 or higher (your toolkit provides CUDA $(release()))"
    elseif release() > CUDAdrv.release()
        silent || @warn """You are using CUDA toolkit $(release()) with a driver that only supports up to $(CUDAdrv.release()).
                           It is recommended to upgrade your driver, or switch to automatic installation of CUDA."""
    end

    llvm_support = llvm_compat(llvm_version)
    cuda_support = cuda_compat()

    target_support[] = sort(collect(llvm_support.cap ∩ cuda_support.cap))
    isempty(target_support[]) && error("Your toolchain does not support any device capability")

    ptx_support[] = sort(collect(llvm_support.ptx ∩ cuda_support.ptx))
    isempty(ptx_support[]) && error("Your toolchain does not support any PTX ISA")

    @debug("CUDAnative supports devices $(verlist(target_support[])); PTX $(verlist(ptx_support[]))")
end
