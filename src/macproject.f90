module macproject_module

  use bl_types
  use ml_layout_module
  use define_bc_module
  use multifab_module
  use bl_constants_module
  use bl_error_module

  use bc_module 

  implicit none

  private

  public :: macproject

contains 

  subroutine macproject(mla,umac,rho,mac_rhs,dx,the_bc_tower,bc_comp)

    use probin_module            , only : stencil_order, use_hypre
    use mac_hypre_module         , only : mac_hypre
    use mac_multigrid_module     , only : mac_multigrid
    use create_umac_grown_module , only : create_umac_grown
    use bndry_reg_module

    type(ml_layout), intent(in   ) :: mla
    type(multifab ), intent(inout) :: umac(:,:)
    type(multifab ), intent(inout) :: rho(:)
    type(multifab ), intent(inout) :: mac_rhs(:)
    real(dp_t)     , intent(in   ) :: dx(:,:)
    type(bc_tower ), intent(in   ) :: the_bc_tower
    integer        , intent(in   ) :: bc_comp

    ! Local  
    type(multifab)  :: rh(mla%nlevel),phi(mla%nlevel)
    type(multifab)  :: alpha(mla%nlevel),beta(mla%nlevel,mla%dim)
    type(bndry_reg) :: fine_flx(mla%nlevel)
    real(dp_t)      :: umac_norm(mla%nlevel)
    real(dp_t)      :: rel_solver_eps
    real(dp_t)      :: abs_solver_eps
    integer         :: d,dm,i,n, nlevs

    nlevs = mla%nlevel
    dm = mla%dim

    do n = 1, nlevs
       call multifab_build(   rh(n), mla%la(n),  1, 0)
       call multifab_build(  phi(n), mla%la(n),  1, 1)
       call multifab_build(alpha(n), mla%la(n),  1, 0)
       do d = 1,dm
          call multifab_build_edge( beta(n,d), mla%la(n), 1, 0, d)
       end do

       call setval(alpha(n),ZERO,all=.true.)
       call setval(  phi(n),ZERO,all=.true.)

    end do

    ! Compute umac_norm to be used inside the MG solver as part of a stopping criterion
    umac_norm = -1.0_dp_t
    do n = 1,nlevs
       do i = 1,dm
          umac_norm(n) = max(umac_norm(n),norm_inf(umac(n,i)))
       end do
    end do

    call divumac(nlevs,umac,mac_rhs,rh,dx,mla%mba%rr,.true.)

    call mk_mac_coeffs(nlevs,mla,rho,beta,the_bc_tower)

    do n = 1,nlevs
       call bndry_reg_build(fine_flx(n),mla%la(n),ml_layout_get_pd(mla,n))
    end do

    if (nlevs .eq. 1) then
       rel_solver_eps = 1.d-12
    else if (nlevs .eq. 2) then
       rel_solver_eps = 1.d-11
    else
       rel_solver_eps = 1.d-10
    endif

    abs_solver_eps = -1.0_dp_t
    do n = 1,nlevs
       abs_solver_eps = max(abs_solver_eps, umac_norm(n) / dx(n,1))
    end do
    abs_solver_eps = rel_solver_eps * abs_solver_eps

    ! HACK FOR THIS TEST
    rel_solver_eps = 1.d-10
    abs_solver_eps = -1.d0

    if (use_hypre .eq. 1) then
       call mac_hypre(mla,rh,phi,fine_flx,alpha,beta,dx,the_bc_tower,bc_comp, &
                      stencil_order,rel_solver_eps,abs_solver_eps)
    else
       call mac_multigrid(mla,rh,phi,fine_flx,alpha,beta,dx,the_bc_tower,bc_comp, &
                          stencil_order,rel_solver_eps,abs_solver_eps)
    end if

    call mkumac(mla,umac,phi,beta,fine_flx,dx,the_bc_tower,bc_comp)

    call divumac(nlevs,umac,mac_rhs,rh,dx,mla%mba%rr,.false.)

    if (nlevs .gt. 1) then
       do n=2,nlevs
          call create_umac_grown(umac(n,:),umac(n-1,:), &
                                 the_bc_tower%bc_tower_array(n-1), &
                                 the_bc_tower%bc_tower_array(n), &
                                 n.eq.nlevs)
       end do
    else
       do n=1,nlevs
          do i=1,dm
             call multifab_fill_boundary(umac(n,i))
          end do
       end do
    end if

    do n = 1, nlevs
       call multifab_destroy(rh(n))
       call multifab_destroy(phi(n))
       call multifab_destroy(alpha(n))
       do d = 1,dm
          call multifab_destroy(beta(n,d))
       end do
    end do

    do n = 1,nlevs
       call bndry_reg_destroy(fine_flx(n))
    end do

  contains

    subroutine divumac(nlevs,umac,mac_rhs,rh,dx,ref_ratio,before)

      use ml_cc_restriction_module, only: ml_cc_restriction
      use probin_module, only: verbose

      integer        , intent(in   ) :: nlevs
      type(multifab) , intent(in   ) :: umac(:,:)
      type(multifab ), intent(in   ) :: mac_rhs(:)
      type(multifab) , intent(inout) :: rh(:)
      real(kind=dp_t), intent(in   ) :: dx(:,:)
      integer        , intent(in   ) :: ref_ratio(:,:)
      logical        , intent(in   ) :: before

      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: vmp(:,:,:,:) 
      real(kind=dp_t), pointer :: wmp(:,:,:,:) 
      real(kind=dp_t), pointer :: rhp(:,:,:,:) 
      real(kind=dp_t)          :: rhmax
      integer :: i,dm,ng_u,ng_r,lo(rh(nlevs)%dim),hi(rh(nlevs)%dim)

      type(bl_prof_timer), save :: bpt

      call build(bpt,"divumac")

      dm = rh(nlevs)%dim

      ng_u = umac(1,1)%ng
      ng_r = rh(1)%ng

      do n = 1,nlevs
         do i = 1, nfabs(rh(n))
            ump => dataptr(umac(n,1), i)
            vmp => dataptr(umac(n,2), i)
            rhp => dataptr(rh(n)  , i)
            lo =  lwb(get_box(rh(n), i))
            hi =  upb(get_box(rh(n), i))
            select case (dm)
            case (2)
               call divumac_2d(ump(:,:,1,1), vmp(:,:,1,1), ng_u, rhp(:,:,1,1), ng_r, &
                               dx(n,:),lo,hi)
            case (3)
               wmp => dataptr(umac(n,3), i)
               call divumac_3d(ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), ng_u, &
                               rhp(:,:,:,1), ng_r, dx(n,:),lo,hi)
            end select
         end do
      end do

      !     NOTE: the sign convention is because the elliptic solver solves
      !            (alpha MINUS del dot beta grad) phi = RHS
      !            Here alpha is zero.

      !     Set rh = divu_rhs - rh
      do n = 1, nlevs
         call multifab_mult_mult_s(rh(n),-ONE)
      end do

      do n = 1, nlevs
         call multifab_plus_plus(rh(n),mac_rhs(n),0)
      end do

!     do n = 1, nlevs
!        call multifab_sub_sub(rh(n),mac_rhs(n))
!        call multifab_mult_mult_s(rh(n),-ONE)
!     end do

      rhmax = norm_inf(rh(nlevs))
      do n = nlevs,2,-1
         call ml_cc_restriction(rh(n-1),rh(n),ref_ratio(n-1,:))
         rhmax = max(rhmax,norm_inf(rh(n-1)))
      end do

      if (parallel_IOProcessor() .and. verbose .ge. 1) then
         if (before) then 
            write(6,1000) 
            write(6,1001) rhmax
         else
            write(6,1002) rhmax
            write(6,1000) 
         end if
      end if

1000  format(' ')
1001  format('... before mac_projection: max of [div (coeff * UMAC) - RHS)]',e15.8)
1002  format('...  after mac_projection: max of [div (coeff * UMAC) - RHS)]',e15.8)

      call destroy(bpt)

    end subroutine divumac

    subroutine divumac_2d(umac,vmac,ng_um,rh,ng_rh,dx,lo,hi)

      integer        , intent(in   ) :: lo(:),hi(:),ng_um,ng_rh
      real(kind=dp_t), intent(in   ) :: umac(lo(1)-ng_um:,lo(2)-ng_um:)
      real(kind=dp_t), intent(in   ) :: vmac(lo(1)-ng_um:,lo(2)-ng_um:)
      real(kind=dp_t), intent(inout) ::   rh(lo(1)-ng_rh:,lo(2)-ng_rh:)
      real(kind=dp_t), intent(in   ) ::   dx(:)

      integer :: i,j
      real(kind=dp_t) :: dxinv(2)

      dxinv(1) = 1.d0 / dx(1)
      dxinv(2) = 1.d0 / dx(2)

      do j = lo(2),hi(2)
         do i = lo(1),hi(1)
            rh(i,j) = (umac(i+1,j) - umac(i,j)) * dxinv(1) + &
                      (vmac(i,j+1) - vmac(i,j)) * dxinv(2)
         end do
      end do

    end subroutine divumac_2d

    subroutine divumac_3d(umac,vmac,wmac,ng_um,rh,ng_rh,dx,lo,hi)

      integer        , intent(in   ) :: lo(:),hi(:),ng_um,ng_rh
      real(kind=dp_t), intent(in   ) :: umac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(in   ) :: vmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(in   ) :: wmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(inout) ::   rh(lo(1)-ng_rh:,lo(2)-ng_rh:,lo(3)-ng_rh:)
      real(kind=dp_t), intent(in   ) :: dx(:)

      integer :: i,j,k
      real(kind=dp_t) :: dxinv(3)

      dxinv(1) = 1.d0 / dx(1)
      dxinv(2) = 1.d0 / dx(2)
      dxinv(3) = 1.d0 / dx(3)

      !$OMP PARALLEL DO PRIVATE(i,j,k)
      do k = lo(3),hi(3)
         do j = lo(2),hi(2)
            do i = lo(1),hi(1)
               rh(i,j,k) = (umac(i+1,j,k) - umac(i,j,k)) * dxinv(1) + &
                           (vmac(i,j+1,k) - vmac(i,j,k)) * dxinv(2) + &
                           (wmac(i,j,k+1) - wmac(i,j,k)) * dxinv(3)
            end do
         end do
      end do
      !$OMP END PARALLEL DO 

    end subroutine divumac_3d

    subroutine mk_mac_coeffs(nlevs,mla,rho,beta,the_bc_tower)

      use ml_cc_restriction_module, only: ml_edge_restriction
      use multifab_fill_ghost_module

      integer        , intent(in   ) :: nlevs
      type(ml_layout), intent(in   ) :: mla
      type(multifab ), intent(inout) :: rho(:)
      type(multifab ), intent(inout) :: beta(:,:)
      type(bc_tower ), intent(in   ) :: the_bc_tower

      real(kind=dp_t), pointer :: bxp(:,:,:,:) 
      real(kind=dp_t), pointer :: byp(:,:,:,:) 
      real(kind=dp_t), pointer :: bzp(:,:,:,:) 
      real(kind=dp_t), pointer :: rp(:,:,:,:) 

      integer :: lo(mla%dim),hi(mla%dim)
      integer :: i,dm,ng_r,ng_b,ng_fill 

      dm   = mla%dim
      ng_r = nghost(rho(nlevs))
      ng_b = nghost(beta(nlevs,1))

      ng_fill = 1
      do n = 2, nlevs
         call multifab_fill_ghost_cells(rho(n),rho(n-1), &
                                        ng_fill,mla%mba%rr(n-1,:), &
                                        the_bc_tower%bc_tower_array(n-1), &
                                        the_bc_tower%bc_tower_array(n  ), &
                                        1,dm+1,1)
      end do

      do n = 1, nlevs
         do i = 1, nfabs(rho(n))
            rp => dataptr(rho(n) , i)
            bxp => dataptr(beta(n,1), i)
            byp => dataptr(beta(n,2), i)
            lo  = lwb(get_box(rho(n),i))
            hi  = upb(get_box(rho(n),i))
            select case (dm)
            case (2)
               call mk_mac_coeffs_2d(bxp(:,:,1,1),byp(:,:,1,1),ng_b,rp(:,:,1,1),ng_r,lo,hi)
            case (3)
               bzp => dataptr(beta(n,3), i)
               call mk_mac_coeffs_3d(bxp(:,:,:,1),byp(:,:,:,1),bzp(:,:,:,1),ng_b,rp(:,:,:,1),ng_r,lo,hi)
            end select
         end do
      end do

      ! Make sure that the fine edges average down onto the coarse edges.
      do n = nlevs,2,-1
         do i = 1,dm
            call ml_edge_restriction(beta(n-1,i),beta(n,i),mla%mba%rr(n-1,:),i)
         end do
      end do

    end subroutine mk_mac_coeffs

    subroutine mk_mac_coeffs_2d(betax,betay,ng_b,rho,ng_r,lo,hi)

      integer        , intent(in   ) :: ng_b,ng_r,lo(:),hi(:)
      real(kind=dp_t), intent(inout) :: betax(lo(1)-ng_b:,lo(2)-ng_b:)
      real(kind=dp_t), intent(inout) :: betay(lo(1)-ng_b:,lo(2)-ng_b:)
      real(kind=dp_t), intent(in   ) ::   rho(lo(1)-ng_r:,lo(2)-ng_r:)

      integer :: i,j

      do j = lo(2),hi(2)
         do i = lo(1),hi(1)+1
            betax(i,j) = TWO / (rho(i,j) + rho(i-1,j))
         end do
      end do

      do j = lo(2),hi(2)+1
         do i = lo(1),hi(1)
            betay(i,j) = TWO / (rho(i,j) + rho(i,j-1))
         end do
      end do

    end subroutine mk_mac_coeffs_2d

    subroutine mk_mac_coeffs_3d(betax,betay,betaz,ng_b,rho,ng_r,lo,hi)

      integer        , intent(in   ) :: ng_b,ng_r,lo(:),hi(:)
      real(kind=dp_t), intent(inout) :: betax(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(inout) :: betay(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(inout) :: betaz(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(in   ) ::   rho(lo(1)-ng_r:,lo(2)-ng_r:,lo(3)-ng_r:)

      integer :: i,j,k

      !$OMP PARALLEL PRIVATE(i,j,k)
      !$OMP DO
      do k = lo(3),hi(3)
         do j = lo(2),hi(2)
            do i = lo(1),hi(1)+1
               betax(i,j,k) = TWO / (rho(i,j,k) + rho(i-1,j,k))
            end do
         end do
      end do
      !$OMP END DO NOWAIT
      !$OMP DO
      do k = lo(3),hi(3)
         do j = lo(2),hi(2)+1
            do i = lo(1),hi(1)
               betay(i,j,k) = TWO / (rho(i,j,k) + rho(i,j-1,k))
            end do
         end do
      end do
      !$OMP END DO NOWAIT
      !$OMP DO
      do k = lo(3),hi(3)+1
         do j = lo(2),hi(2)
            do i = lo(1),hi(1)
               betaz(i,j,k) = TWO / (rho(i,j,k) + rho(i,j,k-1))
            end do
         end do
      end do
      !$OMP END DO
      !$OMP END PARALLEL

    end subroutine mk_mac_coeffs_3d

    subroutine mkumac(mla,umac,phi,beta,fine_flx,dx,the_bc_tower,press_comp)

      use ml_cc_restriction_module, only: ml_edge_restriction

      type(ml_layout),intent(in   ) :: mla
      type(multifab), intent(inout) :: umac(:,:)
      type(multifab), intent(in   ) ::  phi(:)
      type(multifab), intent(in   ) :: beta(:,:)
      type(bndry_reg),intent(in   ) :: fine_flx(:)
      real(dp_t)    , intent(in   ) :: dx(:,:)
      type(bc_tower), intent(in   ) :: the_bc_tower
      integer       , intent(in   ) :: press_comp

      integer :: i,ng_um,ng_p,ng_b,lo(get_dim(phi(1))),hi(get_dim(phi(1))),dm

      type(bc_level)           :: bc
      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: vmp(:,:,:,:) 
      real(kind=dp_t), pointer :: wmp(:,:,:,:) 
      real(kind=dp_t), pointer :: php(:,:,:,:) 
      real(kind=dp_t), pointer :: bxp(:,:,:,:) 
      real(kind=dp_t), pointer :: byp(:,:,:,:) 
      real(kind=dp_t), pointer :: bzp(:,:,:,:) 
      real(kind=dp_t), pointer :: lxp(:,:,:,:) 
      real(kind=dp_t), pointer :: hxp(:,:,:,:) 
      real(kind=dp_t), pointer :: lyp(:,:,:,:) 
      real(kind=dp_t), pointer :: hyp(:,:,:,:) 
      real(kind=dp_t), pointer :: lzp(:,:,:,:) 
      real(kind=dp_t), pointer :: hzp(:,:,:,:) 

      type(bl_prof_timer), save :: bpt

      call build(bpt,"mkumac")

      dm = get_dim(phi(1))
      nlevs = size(phi)

      ng_um = nghost(umac(1,1))
      ng_p = nghost(phi(1))
      ng_b = nghost(beta(1,1))

      do n = 1, nlevs
         bc = the_bc_tower%bc_tower_array(n)
         do i = 1, nfabs(phi(n))
            ump => dataptr(umac(n,1), i)
            php => dataptr( phi(n), i)
            bxp => dataptr(beta(n,1), i)
            lo  =  lwb(get_box(phi(n), i))
            hi  =  upb(get_box(phi(n), i))
            lxp => dataptr(fine_flx(n)%bmf(1,0), i)
            hxp => dataptr(fine_flx(n)%bmf(1,1), i)

            select case (dm)
            case (1)
               call mkumac_1d(ump(:,1,1,1), ng_um, & 
                              php(:,1,1,1), ng_p, &
                              bxp(:,1,1,1), ng_b, &
                              lxp(:,1,1,1),hxp(:,1,1,1), &
                              lo,hi,dx(n,:),bc%ell_bc_level_array(i,:,:,press_comp))
            case (2)
               vmp => dataptr(umac(n,2), i)
               byp => dataptr(beta(n,2), i)
               lyp => dataptr(fine_flx(n)%bmf(2,0), i)
               hyp => dataptr(fine_flx(n)%bmf(2,1), i)
               call mkumac_2d(ump(:,:,1,1),vmp(:,:,1,1),  ng_um, &
                              php(:,:,1,1),               ng_p, &
                              bxp(:,:,1,1), byp(:,:,1,1), ng_b,&
                              lxp(:,:,1,1),hxp(:,:,1,1),lyp(:,:,1,1),hyp(:,:,1,1), &
                              lo,hi,dx(n,:),bc%ell_bc_level_array(i,:,:,press_comp))

            case (3)
               vmp => dataptr(umac(n,2), i)
               wmp => dataptr(umac(n,3), i)
               byp => dataptr(beta(n,2), i)
               bzp => dataptr(beta(n,3), i)
               lyp => dataptr(fine_flx(n)%bmf(2,0), i)
               hyp => dataptr(fine_flx(n)%bmf(2,1), i)
               lzp => dataptr(fine_flx(n)%bmf(3,0), i)
               hzp => dataptr(fine_flx(n)%bmf(3,1), i)
               call mkumac_3d(ump(:,:,:,1),vmp(:,:,:,1),wmp(:,:,:,1), ng_um,&
                              php(:,:,:,1),                             ng_p, &
                              bxp(:,:,:,1), byp(:,:,:,1), bzp(:,:,:,1), ng_b, &
                              lxp(:,:,:,1),hxp(:,:,:,1),lyp(:,:,:,1),hyp(:,:,:,1), &
                              lzp(:,:,:,1),hzp(:,:,:,1), &
                              lo,hi,dx(n,:),bc%ell_bc_level_array(i,:,:,press_comp))
            end select
         end do

         do d=1,dm
            call multifab_fill_boundary(umac(n,d))
         enddo

      end do
      
      do n = nlevs,2,-1
         do i = 1,dm
            call ml_edge_restriction(umac(n-1,i),umac(n,i),mla%mba%rr(n-1,:),i)
         end do
      end do

      call destroy(bpt)

    end subroutine mkumac

    subroutine mkumac_1d(umac,ng_um,phi,ng_p,betax,ng_b,lo_x_flx,hi_x_flx,lo,hi,dx,press_bc)

      integer        , intent(in   ) :: lo(:),hi(:)
      integer        , intent(in   ) :: ng_um,ng_p,ng_b
      real(kind=dp_t), intent(inout) ::  umac(lo(1)-ng_um:)
      real(kind=dp_t), intent(inout) ::   phi(lo(1)-ng_p:)
      real(kind=dp_t), intent(in   ) :: betax(lo(1)-ng_b:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      integer :: i

      ! At boundaries of grid
      umac(lo(1)  ) = umac(lo(1)  ) - lo_x_flx(1) * dx(1)
      umac(hi(1)+1) = umac(hi(1)+1) + hi_x_flx(1) * dx(1)

      ! In interior of grid
      do i = lo(1)+1, hi(1)
         umac(i) = umac(i) - betax(i) * (phi(i) - phi(i-1)) / dx(1)
      end do


    end subroutine mkumac_1d

    subroutine mkumac_2d(umac,vmac,ng_um,phi,ng_p,betax,betay,ng_b, &
                         lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx, &
                         lo,hi,dx,press_bc)

      integer        , intent(in   ) :: lo(:),hi(:)
      integer        , intent(in   ) :: ng_um,ng_p,ng_b
      real(kind=dp_t), intent(inout) ::  umac(lo(1)-ng_um:,lo(2)-ng_um:)
      real(kind=dp_t), intent(inout) ::  vmac(lo(1)-ng_um:,lo(2)-ng_um:)
      real(kind=dp_t), intent(inout) ::   phi(lo(1)-ng_p: ,lo(2)-ng_p:)
      real(kind=dp_t), intent(in   ) :: betax(lo(1)-ng_b: ,lo(2)-ng_b:)
      real(kind=dp_t), intent(in   ) :: betay(lo(1)-ng_b: ,lo(2)-ng_b:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,lo(2):), lo_y_flx(lo(1):,:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:,lo(2):), hi_y_flx(lo(1):,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gphix,gphiy
      integer :: i,j

      do j = lo(2),hi(2)

         umac(lo(1)  ,j) = umac(lo(1)  ,j) - lo_x_flx(1,j) * dx(1)
         umac(hi(1)+1,j) = umac(hi(1)+1,j) + hi_x_flx(1,j) * dx(1)

         do i = lo(1)+1,hi(1)
            gphix = (phi(i,j) - phi(i-1,j)) / dx(1)
            umac(i,j) = umac(i,j) - betax(i,j)*gphix
         end do

      end do

      do i = lo(1),hi(1)

         vmac(i,lo(2)  ) = vmac(i,lo(2)  ) - lo_y_flx(i,1) * dx(2)
         vmac(i,hi(2)+1) = vmac(i,hi(2)+1) + hi_y_flx(i,1) * dx(2)

         do j = lo(2)+1,hi(2)
            gphiy = (phi(i,j) - phi(i,j-1)) / dx(2)
            vmac(i,j) = vmac(i,j) - betay(i,j)*gphiy
         end do

      end do

    end subroutine mkumac_2d

    subroutine mkumac_3d(umac,vmac,wmac,   ng_um,&
                         phi,              ng_p, &
                         betax,betay,betaz,ng_b, &
                         lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx,lo_z_flx,hi_z_flx,&
                         lo,hi,dx,press_bc)

      integer        , intent(in   ) :: lo(:),hi(:)
      integer        , intent(in   ) :: ng_um,ng_p,ng_b
      real(kind=dp_t), intent(inout) :: umac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(inout) :: vmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(inout) :: wmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
      real(kind=dp_t), intent(inout) ::  phi(lo(1)-ng_p:,lo(2)-ng_p:,lo(3)-ng_p:)
      real(kind=dp_t), intent(in   ) :: betax(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(in   ) :: betay(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(in   ) :: betaz(lo(1)-ng_b:,lo(2)-ng_b:,lo(3)-ng_b:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,lo(2):,lo(3):), hi_x_flx(:,lo(2):,lo(3):)
      real(kind=dp_t), intent(in   ) :: lo_y_flx(lo(1):,:,lo(3):), hi_y_flx(lo(1):,:,lo(3):)
      real(kind=dp_t), intent(in   ) :: lo_z_flx(lo(1):,lo(2):,:), hi_z_flx(lo(1):,lo(2):,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gphix,gphiy,gphiz
      integer :: i,j,k

      ! NOTE THAT THIS ASSUMES THAT LO, HI ARE THE GRID LIMITS, NOT TILE LIMITS!

      !$OMP PARALLEL PRIVATE(i,j,k,gphix,gphiy,gphiz)
      !$OMP DO
      do k = lo(3),hi(3)
         do j = lo(2),hi(2)
            umac(lo(1)  ,j,k) = umac(lo(1)  ,j,k) - lo_x_flx(1,j,k) * dx(1)
            umac(hi(1)+1,j,k) = umac(hi(1)+1,j,k) + hi_x_flx(1,j,k) * dx(1)
            do i = lo(1)+1,hi(1)
               gphix = (phi(i,j,k) - phi(i-1,j,k)) / dx(1)
               umac(i,j,k) = umac(i,j,k) - betax(i,j,k)*gphix
            end do
         end do
      end do
      !$OMP END DO NOWAIT

      !$OMP DO
      do k = lo(3),hi(3)
         do i = lo(1),hi(1)
            vmac(i,lo(2)  ,k) = vmac(i,lo(2)  ,k) - lo_y_flx(i,1,k) * dx(2)
            vmac(i,hi(2)+1,k) = vmac(i,hi(2)+1,k) + hi_y_flx(i,1,k) * dx(2)
            do j = lo(2)+1,hi(2)
               gphiy = (phi(i,j,k) - phi(i,j-1,k)) / dx(2)
               vmac(i,j,k) = vmac(i,j,k) - betay(i,j,k)*gphiy
            end do
         end do
      end do
      !$OMP END DO NOWAIT

      !$OMP DO
      do j = lo(2),hi(2)
         do i = lo(1),hi(1)
            wmac(i,j,lo(3)  ) = wmac(i,j,lo(3)  ) - lo_z_flx(i,j,1) * dx(3)
            wmac(i,j,hi(3)+1) = wmac(i,j,hi(3)+1) + hi_z_flx(i,j,1) * dx(3)
            do k = lo(3)+1,hi(3)
               gphiz = (phi(i,j,k) - phi(i,j,k-1)) / dx(3)
               wmac(i,j,k) = wmac(i,j,k) - betaz(i,j,k)*gphiz
            end do
         end do
      end do
      !$OMP END DO
      !$OMP END PARALLEL

    end subroutine mkumac_3d

  end subroutine macproject

end module macproject_module
