module m_cuda_backend
   use cudafor

   use m_allocator, only: allocator_t, field_t
   use m_cuda_allocator, only: cuda_allocator_t, cuda_field_t
   use m_base_backend, only: base_backend_t
   use m_common, only: dp, globs_t
   use m_cuda_common, only: SZ
   use m_tdsops, only: dirps_t
   use m_cuda_tdsops, only: cuda_tdsops_t
   use m_cuda_kernels_dist, only: der_univ_dist, der_univ_subs

   implicit none

   type, extends(base_backend_t) :: cuda_backend_t
      !character(len=*), parameter :: name = 'cuda'
      integer :: MPI_FP_PREC = dp
      real(dp), device, allocatable, dimension(:, :, :) :: &
         u_recv_s_dev, u_recv_e_dev, u_send_s_dev, u_send_e_dev, &
         send_s_dev, send_e_dev, recv_s_dev, recv_e_dev
      type(dim3) :: xblocks, xthreads, yblocks, ythreads, zblocks, zthreads
    contains
      procedure :: transeq_x => transeq_x_cuda
      procedure :: transeq_y => transeq_y_cuda
      procedure :: transeq_z => transeq_z_cuda
      procedure :: trans_x2y => trans_x2y_cuda
      procedure :: trans_x2z => trans_x2z_cuda
      procedure :: sum_yzintox => sum_yzintox_cuda
      procedure :: transeq_cuda_dist
      procedure :: transeq_cuda_thom
   end type cuda_backend_t

   interface cuda_backend_t
      module procedure constructor
   end interface cuda_backend_t

 contains

   function constructor(globs, allocator, xdirps, ydirps, zdirps) &
      result(backend)
      implicit none

      class(globs_t) :: globs
      class(allocator_t), target, intent(inout) :: allocator
      class(dirps_t), target, intent(inout) :: xdirps, ydirps, zdirps
      type(cuda_backend_t) :: backend

      integer :: n_halo, n_block

      select type(allocator)
      type is (cuda_allocator_t)
      ! class level access to the allocator
      backend%allocator => allocator
      end select
      ! class level access to derivative parameters
      backend%xdirps => xdirps
      backend%ydirps => ydirps
      backend%zdirps => zdirps
      print*, 'assignments done'

      backend%xthreads = dim3(SZ, 1, 1)
      backend%xblocks = dim3(1, 1, 1)

      allocate(cuda_tdsops_t :: backend%xdirps%der1st)
      allocate(cuda_tdsops_t :: backend%ydirps%der1st)
      allocate(cuda_tdsops_t :: backend%zdirps%der1st)

      select type (der1st => backend%xdirps%der1st)
      type is (cuda_tdsops_t)
         der1st = cuda_tdsops_t(globs%nx_loc, globs%dx, &
                                'first-deriv', 'compact6')
      end select
      select type (der1st => backend%ydirps%der1st)
      type is (cuda_tdsops_t)
         der1st = cuda_tdsops_t(globs%ny_loc, globs%dy, &
                                'first-deriv', 'compact6')
      end select
      select type (der1st => backend%zdirps%der1st)
      type is (cuda_tdsops_t)
         der1st = cuda_tdsops_t(globs%nz_loc, globs%dz, &
                                'first-deriv', 'compact6')
      end select
      !print*, backend%ydirps%der1st%coeffs

      print*, 'der1sts assigned'


      n_halo = 4
      n_block = ydirps%n*zdirps%n/SZ

      allocate(backend%u_send_s_dev(SZ, n_halo, n_block))
      allocate(backend%u_send_e_dev(SZ, n_halo, n_block))
      allocate(backend%u_recv_s_dev(SZ, n_halo, n_block))
      allocate(backend%u_recv_e_dev(SZ, n_halo, n_block))

      allocate(backend%send_s_dev(SZ, 1, n_block))
      allocate(backend%send_e_dev(SZ, 1, n_block))
      allocate(backend%recv_s_dev(SZ, 1, n_block))
      allocate(backend%recv_e_dev(SZ, 1, n_block))

      ! Assign transeq_? into right functions
      ! The idea is that these assignments will be conditional
      !backend%transeq_x => transeq_cuda_dist
      !backend%transeq_x => transeq_cuda_thom
      !backend%transeq_y => transeq_cuda_dist
      !backend%transeq_z => transeq_cuda_dist

   end function constructor

   subroutine transeq_x_cuda(self, du, dv, dw, u, v, w, dirps)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, dv, dw
      class(field_t), intent(in) :: u, v, w
      type(dirps_t), intent(in) :: dirps

      print*, 'transeq_x_cuda'
      call self%transeq_cuda_dist(du, dv, dw, u, v, w, dirps, &
                                  self%xthreads, self%xblocks)

   end subroutine transeq_x_cuda

   subroutine transeq_y_cuda(self, du, dv, dw, u, v, w, dirps)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, dv, dw
      class(field_t), intent(in) :: u, v, w
      type(dirps_t), intent(in) :: dirps

      print*, 'transeq_y_cuda'
      ! u, v, w is reordered so that we pass v, u, w
      call self%transeq_cuda_dist(dv, du, dw, v, u, w, dirps, &
                                  self%ythreads, self%yblocks)

   end subroutine transeq_y_cuda

   subroutine transeq_z_cuda(self, du, dv, dw, u, v, w, dirps)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, dv, dw
      class(field_t), intent(in) :: u, v, w
      type(dirps_t), intent(in) :: dirps

      print*, 'transeq_z_cuda'
      ! w, u, v is reordered so that we pass w, u, v
      call self%transeq_cuda_dist(dw, du, dv, w, u, v, dirps, &
                                  self%zthreads, self%zblocks)

   end subroutine transeq_z_cuda

   subroutine transeq_cuda_dist(self, du, duu, d2u, u, v, w, dirps, &
                                blocks, threads)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, duu, d2u
      class(field_t), intent(in) :: u, v, w
      type(dirps_t), intent(in) :: dirps
      type(dim3), intent(in) :: blocks, threads

      class(field_t), pointer :: temp_du, temp_duu, temp_d2u, &
                                 temp_dv, temp_dvu, temp_d2v, &
                                 temp_dw, temp_dwu, temp_d2w

      real(dp), device, pointer, dimension(:, :, :) :: du_dev, duu_dev, d2u_dev, &
                                                   dv_dev, dvu_dev, d2v_dev, &
                                                   dw_dev, dwu_dev, d2w_dev

      real(dp), device, pointer, dimension(:, :, :) :: u_dev

      type(cuda_tdsops_t), pointer :: local_der1st

      print*, 'transeq_cuda_dist'
      ! MPI communication for halo data
      ! first slice the halo data
      !call slice_layers<<<blocks, threads>>>(u, buff_send_u_b, buff_send_u_e, derps%n_halo)
      !call slice_layers<<<blocks, threads>>>(v, buff_send_v_b, buff_send_v_e, derps%n_halo)
      !call slice_layers<<<blocks, threads>>>(w, buff_send_w_b, buff_send_w_e, derps%n_halo)

      ! then send/recv halos
      !call communicate_sendrecv(
      !   buff_send_u_b, buff_send_u_e, buff_recv_u_b, buff_recv_u_e, &
      !   derps%n_halo*derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   buff_send_v_b, buff_send_v_e, buff_recv_v_b, buff_recv_v_e, &
      !   derps%n_halo*derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   buff_send_w_b, buff_send_w_e, buff_recv_w_b, buff_recv_w_e, &
      !   derps%n_halo*derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)

      ! distder_cuda

      ! get some fields for storing the result
      temp_du => self%allocator%get_block()
      temp_duu => self%allocator%get_block()
      temp_d2u => self%allocator%get_block()
      print*, 'get fields'

      select type(temp_du)
      type is (cuda_field_t); du_dev => temp_du%data_d
      end select
      select type(temp_duu)
      type is (cuda_field_t); duu_dev => temp_duu%data_d
      end select
      select type(temp_d2u)
      type is (cuda_field_t); d2u_dev => temp_d2u%data_d
      end select
      print*, 'set device pointers'

      select type (der1st => dirps%der1st)
      type is (cuda_tdsops_t)
         local_der1st => der1st
      end select

      select type(u)
      type is (cuda_field_t); u_dev => u%data_d
      end select

      call der_univ_dist<<<blocks, threads>>>( &
         du_dev, self%send_s_dev, self%send_e_dev, u_dev, &
         self%u_recv_s_dev, self%u_recv_e_dev, &
         local_der1st%coeffs_s_dev, local_der1st%coeffs_e_dev, &
         local_der1st%coeffs_dev, local_der1st%n, &
         local_der1st%dist_fw_dev, local_der1st%dist_bw_dev, &
         local_der1st%dist_af_dev &
      )
      ! this functions is not yet implemented, but is very similar to the one we have
      !call transeq_fused_dist<<<blocks, threads>>>( &
      !   du_dev, duu_dev, d2u_dev, &
      !   u, u, derps%n, self%nu, &
      !   derps%fdist_bc_dev, derps%fdist_fr_dev, derps%sdist_bc_dev, derps%sdist_fr_dev, &
      !   derps%alfai, derps%afi, derps%bfi, &
      !   derps%alsai, derps%asi, derps%bsi, derps%csi, derps%dsi &
      !)

      temp_dv => self%allocator%get_block()
      temp_dvu => self%allocator%get_block()
      temp_d2v => self%allocator%get_block()

      select type(temp_dv)
      type is (cuda_field_t); dv_dev => temp_dv%data_d
      end select
      select type(temp_dvu)
      type is (cuda_field_t); dvu_dev => temp_dvu%data_d
      end select
      select type(temp_d2v)
      type is (cuda_field_t); d2v_dev => temp_d2v%data_d
      end select

      !call transeq_fused_dist<<<blocks, threads>>>( &
      !   temp_dv, temp_dvu, temp_d2v, &
      !   v, conv, derps%n, self%nu, &
      !   derps%fdist_bc_dev, derps%fdist_fr_dev, derps%sdist_bc_dev, derps%sdist_fr_dev, &
      !)

      temp_dw => self%allocator%get_block()
      temp_dwu => self%allocator%get_block()
      temp_d2w => self%allocator%get_block()

      select type(temp_dw)
      type is (cuda_field_t); dw_dev => temp_dw%data_d
      end select
      select type(temp_dwu)
      type is (cuda_field_t); dwu_dev => temp_dwu%data_d
      end select
      select type(temp_d2w)
      type is (cuda_field_t); d2w_dev => temp_d2w%data_d
      end select

      !call transeq_fused_dist<<<blocks, threads>>>( &
      !   temp_dw, temp_dwu, temp_d2w, &
      !   w, conv, derps%n, self%nu, &
      !   derps%fdist_bc_dev, derps%fdist_fr_dev, derps%sdist_bc_dev, derps%sdist_fr_dev, &
      !)

      ! MPI communicaton for the 2x2 systems
      ! each rank sends and recieves from the next and previous ranks
      !call communicate_sendrecv(
      !   slice_send_du_b, slice_send_du_e, slice_recv_du_b, slice_recv_du_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_duu_b, slice_send_duu_e, slice_recv_duu_b, slice_recv_duu_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_d2u_b, slice_send_d2u_e, slice_recv_d2u_b, slice_recv_d2u_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_dv_b, slice_send_dv_e, slice_recv_dv_b, slice_recv_dv_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_dvu_b, slice_send_dvu_e, slice_recv_dvu_b, slice_recv_dvu_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_d2v_b, slice_send_d2v_e, slice_recv_d2v_b, slice_recv_d2v_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_dw_b, slice_send_dw_e, slice_recv_dw_b, slice_recv_dw_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_dwu_b, slice_send_dwu_e, slice_recv_dwu_b, slice_recv_dwu_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)
      !call communicate_sendrecv(
      !   slice_send_d2w_b, slice_send_d2w_e, slice_recv_d2w_b, slice_recv_d2w_e, &
      !   derps%n_perp, derps%prev_rank, derps%next_rank, self%MPI_FP_PREC &
      !)

      ! get the final result doing a one last pass
      !call transeq_fused_subs<<<blocks, threads>>>( &
      !   slice_recv_du_b, slice_recv_du_e, slice_recv_duu_b, slice_recv_duu_e, slice_recv_d2u_b, slice_recv_d2u_e, &
      !   w, conv, derps%n, self%nu, &
      !   derps%fdist_sa_dev, derps%fdist_sc_dev, derps%sdist_sa_dev, derps%sdist_sc_dev, &
      !)

      ! Finally release temporary blocks
      call self%allocator%release_block(temp_du)
      call self%allocator%release_block(temp_duu)
      call self%allocator%release_block(temp_d2u)
      call self%allocator%release_block(temp_dv)
      call self%allocator%release_block(temp_dvu)
      call self%allocator%release_block(temp_d2v)
      call self%allocator%release_block(temp_dw)
      call self%allocator%release_block(temp_dwu)
      call self%allocator%release_block(temp_d2w)

   end subroutine transeq_cuda_dist

   subroutine transeq_cuda_thom(self, du, dv, dw, u, v, w, dirps)
      !! Thomas algorithm implementation. So much more easier than the
      !! distributed algorithm. It is intended to work only on a single rank
      !! so there is no MPI communication.
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, dv, dw
      class(field_t), intent(in) :: u, v, w
      type(dirps_t), intent(in) :: dirps

!      call transeq_fused_thom_pp<<<derps%blocks, derps%threads>>>( &
!         du, u, conv, derps%ff_dev, derps%fs_dev, derps%fw_dev, derps%fp_dev, &
!         derps%sf_dev, derps%ss_dev, derps%sw_dev, derps%sp_dev, &
!         derps%n, self%nu, derps%alfai, derps%alsai, &
!         derps%afi, derps%bfi, derps%asi, derps%bsi, derps%csi, derps%dsi &
!      )
!      call transeq_fused_thom_pp<<<derps%blocks, derps%threads>>>( &
!         dv, v, conv, derps%ff_dev, derps%fs_dev, derps%fw_dev, derps%fp_dev, &
!         derps%sf_dev, derps%ss_dev, derps%sw_dev, derps%sp_dev, &
!         derps%n, self%nu, derps%alfai, derps%alsai, &
!         derps%afi, derps%bfi, derps%asi, derps%bsi, derps%csi, derps%dsi &
!      )
!      call transeq_fused_thom_pp<<<derps%blocks, derps%threads>>>( &
!         dw, w, conv, derps%ff_dev, derps%fs_dev, derps%fw_dev, derps%fp_dev, &
!         derps%sf_dev, derps%ss_dev, derps%sw_dev, derps%sp_dev, &
!         derps%n, self%nu, derps%alfai, derps%alsai, &
!         derps%afi, derps%bfi, derps%asi, derps%bsi, derps%csi, derps%dsi &
!      )

   end subroutine transeq_cuda_thom

   subroutine trans_x2y_cuda(self, u_y, v_y, w_y, u, v, w)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: u_y, v_y, w_y
      class(field_t), intent(in) :: u, v, w

   end subroutine trans_x2y_cuda

   subroutine trans_x2z_cuda(self, u_z, v_z, w_z, u, v, w)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: u_z, v_z, w_z
      class(field_t), intent(in) :: u, v, w

   end subroutine trans_x2z_cuda

   subroutine sum_yzintox_cuda(self, du, dv, dw, &
                               du_y, dv_y, dw_y, du_z, dv_z, dw_z)
      implicit none

      class(cuda_backend_t) :: self
      class(field_t), intent(inout) :: du, dv, dw
      class(field_t), intent(in) :: du_y, dv_y, dw_y, du_z, dv_z, dw_z

   end subroutine sum_yzintox_cuda

!   subroutine communicate_sendrecv(arr_send_b, arr_send_e, arr_recv_b, arr_recv_e, n_size, prev, next, MPI_FP_PREC)
!      implicit none
!
!      class(field_t), intent(in) :: arr_send_b, arr_send_e
!      class(field_t), intent(inout) :: arr_send_b, arr_send_e
!      integer, intent(in) :: n_size, next, prev, MPI_FP_PREC
!
!      integer :: mpireq(4), srerr(4), tag1 = 1234, tag2 = 2341
!
!      call MPI_Isend(arr_send_b, n_size, &
!                     MPI_FP_PREC, prev, tag1, MPI_COMM_WORLD, mpireq(1), &
!                     srerr(1))
!      call MPI_Isend(arr_send_e, derps%n_perp, &
!                     MPI_FP_PREC, next, tag2, MPI_COMM_WORLD, mpireq(2), &
!                     srerr(2))
!      call MPI_Irecv(arr_recv_b, derps%n_perp, &
!                     MPI_FP_PREC, prev, tag2, MPI_COMM_WORLD, mpireq(3), &
!                     srerr(3))
!      call MPI_Irecv(arr_recv_e, derps%n_perp, &
!                     MPI_FP_PREC, next, tag1, MPI_COMM_WORLD, mpireq(4), &
!                     srerr(4))
!
!      call MPI_Waitall(4, mpireq, MPI_STATUSES_IGNORE, ierr)
!
!   end subroutine communicate_sendrecv

end module m_cuda_backend

