#include <torch/extension.h>
#include <vector>

// #include <stdio.h>  // for debug

#include <cuda.h>
#include <cuda_runtime.h>


#define THREADS_PER_BLOCK 1024

#define PI 3.141592653589793


// definitions of CUDA kernels (executed on: GPU)

template <typename scalar_t>
__global__ void normal_forward_cuda_kernel(
    scalar_t * const __restrict__ x_out,
    const scalar_t * __restrict__ x_in,
    const int64_t len_x,
    const scalar_t * __restrict__ q,
    const scalar_t * __restrict__ t,
    const int64_t len_t,
    const scalar_t * __restrict__ fmu,
    const scalar_t * __restrict__ fsigma,
    const scalar_t * __restrict__ training
)
{
    int ix = blockIdx.x * blockDim.x + threadIdx.x;
    if (ix < len_x)
    {
        float sum = q[0];

        for (int it = 0; it < len_t; ++it)
        {
            // input position relative to the threshold
            float x_minus_t = x_in[ix] - t[it] - *fmu;

            // expected value of the Heaviside function is the CDF of the normal distribution
            float cdf;
            if (*training && (*fsigma != 0.0f))
            {
                float sigma_inv = 1.0f / (*fsigma);
                float x_minus_t_over_s = x_minus_t * sigma_inv;
                cdf = (float) normcdf((double) x_minus_t_over_s);
            }
            else
            {
                cdf = (float) (x_minus_t >= 0.0f); // use the Heaviside which maps zero to one
            }

            // dilate and accumulate expected step value
            float dq = q[it + 1] - q[it];
            sum += dq * cdf;
        }

        x_out[ix] = sum;
    }
    else  // I am out of bounds!
    {
        return;
    }
}


template <typename scalar_t>
__global__ void normal_backward_cuda_kernel(
    scalar_t * const __restrict__ grad_out,
    const scalar_t * __restrict__ grad_in,
    const scalar_t * __restrict__ x_in,
    const int64_t len_x,
    const scalar_t * __restrict__ q,
    const scalar_t * __restrict__ t,
    const int64_t len_t,
    const scalar_t * __restrict__ bmu,
    const scalar_t * __restrict__ bsigma
)
{
    int ix = blockIdx.x * blockDim.x + threadIdx.x;
    if (ix < len_x)
    {
        float sum = 0.0f;

        for (int it = 0; it < len_t; ++it)
        {
            // input position relative to the threshold
            float x_minus_t  = x_in[ix] - t[it] - *bmu;

            // the derivative of the expected (i.e., regularised) step function is the PDF of the normal distribution
            float pdf;
            if (*bsigma != 0.0f)
            {
                float sigma_inv = 1.0f / (*bsigma);
                float x_minus_t_over_s = x_minus_t * sigma_inv;
                float exp_x_minus_t_over_s_square = expf(-(x_minus_t_over_s * x_minus_t_over_s) / 2.0f);
                pdf = exp_x_minus_t_over_s_square * sigma_inv * (1 / sqrt(2 * PI));
            }
            else
            {
                pdf = 0.0f;  // no noise, no gradient!
            }

            // dilate and accumulate expected derivative
            float dq = q[it + 1] - q[it];
            sum += dq * pdf;
        }

        // compose gradients
        grad_out[ix] = sum * grad_in[ix];
    }
    else  // I am out of bounds!
    {
        return;
    }
}


// definitions of C++\CUDA interface (executed on: CPU)
// goals:
//   * allocate GPU memory for the output;
//   * define the parameters for the GPU kernel;
//   * call the kernel;

torch::Tensor normal_forward_cuda_dispatch(
    torch::Tensor x_in,
    torch::Tensor q,
    torch::Tensor t,
    torch::Tensor fmu,
    torch::Tensor fsigma,
    torch::Tensor training
)
{
    auto x_out = torch::zeros_like(x_in);
    const dim3 blocks((x_in.numel() + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK);

    AT_DISPATCH_FLOATING_TYPES(
        x_in.type(),
        "normal_forward_cuda",
        ([&] {
            normal_forward_cuda_kernel<scalar_t><<<blocks, THREADS_PER_BLOCK>>>(
                x_out.data_ptr<scalar_t>(),
                x_in.data_ptr<scalar_t>(),
                x_in.numel(),
                q.data_ptr<scalar_t>(),
                t.data_ptr<scalar_t>(),
                t.numel(),
                fmu.data_ptr<scalar_t>(),
                fsigma.data_ptr<scalar_t>(),
                training.data_ptr<scalar_t>()
            );
        })
    );

    return x_out;
}


torch::Tensor normal_backward_cuda_dispatch(
    torch::Tensor grad_in,
    torch::Tensor x_in,
    torch::Tensor q,
    torch::Tensor t,
    torch::Tensor bmu,
    torch::Tensor bsigma
)
{
    auto grad_out = torch::zeros_like(x_in);
    const dim3 blocks((x_in.numel() + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK);

    AT_DISPATCH_FLOATING_TYPES(
        x_in.type(),
        "normal_backward_cuda",
        ([&] {
            normal_backward_cuda_kernel<scalar_t><<<blocks, THREADS_PER_BLOCK>>>(
                grad_out.data_ptr<scalar_t>(),
                grad_in.data_ptr<scalar_t>(),
                x_in.data_ptr<scalar_t>(),
                x_in.numel(),
                q.data_ptr<scalar_t>(),
                t.data_ptr<scalar_t>(),
                t.numel(),
                bmu.data_ptr<scalar_t>(),
                bsigma.data_ptr<scalar_t>()
            );
        })
    );

    return grad_out;
}
