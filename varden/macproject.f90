module macproject_module

  use bl_types
  use define_bc_module
  use multifab_module
  use boxarray_module
  use stencil_module
  use multifab_fill_ghost_module
  use ml_restriction_module
  use bndry_reg_module
  use fabio_module

  implicit none

contains 

subroutine macproject(mla,umac,rho,dx,the_bc_tower,verbose,mg_verbose,cg_verbose,divu_rhs,div_coeff,div_coeff_half)

  type(ml_layout), intent(inout) :: mla
  type(multifab ), intent(inout) :: umac(:,:)
  type(multifab ), intent(inout) :: rho(:)
  real(dp_t)     , intent(in   ) :: dx(:,:)
  type(bc_tower ), intent(in   ) :: the_bc_tower
  integer        , intent(in   ) :: verbose,mg_verbose,cg_verbose

  type(multifab ), intent(inout), optional :: divu_rhs(:)
  real(dp_t)     , intent(in   ), optional :: div_coeff(:)
  real(dp_t)     , intent(in   ), optional :: div_coeff_half(:)

! Local  
  type(multifab), allocatable :: rh(:),phi(:),alpha(:),beta(:)
  type(bndry_reg), pointer    :: fine_flx(:) => Null()
  real(dp_t)     ,allocatable :: umac_norm(:)
  integer                     :: dm,stencil_order,i,n
  integer                     :: ng,nc
  integer                     :: nlevs,nscal,bc_comp
  logical                     :: use_rhs, use_div_coeff

  nlevs = mla%nlevel
  dm = umac(nlevs,1)%dim
  nscal = 2
  bc_comp = dm + nscal + 1

  use_rhs = .false.
  if (present(divu_rhs)) use_rhs = .true.

  use_div_coeff = .false.
  if (present(div_coeff)) use_div_coeff = .true.

  stencil_order = 2

  allocate(rh(nlevs), phi(nlevs), alpha(nlevs), beta(nlevs))
  allocate(umac_norm(nlevs))

  do n = 1, nlevs
     call multifab_build(   rh(n), mla%la(n),  1, 0)
     call multifab_build(  phi(n), mla%la(n),  1, 1)
     call multifab_build(alpha(n), mla%la(n),  1, 1)
     call multifab_build( beta(n), mla%la(n), dm, 1)

     call setval(alpha(n),ZERO,all=.true.)
     call setval(  phi(n),ZERO,all=.true.)

  end do

  if (use_div_coeff) then
    do n = 1,nlevs
       call mult_umac_by_coeff(umac(n,:),div_coeff,div_coeff_half,.true.)
    end do
  end if

  ! Compute umac_norm to be used inside the MG solver as part of a stopping criterion
  umac_norm = -1.0_dp_t
  do n = 1,nlevs
    do i = 1,dm
      umac_norm(n) = max(umac_norm(n),norm_inf(umac(n,i)))
    end do
  end do

  if (use_rhs) then
    call divumac(nlevs,umac,rh,dx,mla%mba%rr,verbose,.true.,divu_rhs)
  else
    call divumac(nlevs,umac,rh,dx,mla%mba%rr,verbose,.true.)
  end if

  call mk_mac_coeffs(nlevs,mla,rho,beta,the_bc_tower)

  if (use_div_coeff) then
    do n = 1,nlevs
       call mult_beta_by_coeff(beta(n),div_coeff,div_coeff_half)
    end do
  end if

  allocate(fine_flx(2:nlevs))
  do n = 2,nlevs
     call bndry_reg_build(fine_flx(n),mla%la(n),ml_layout_get_pd(mla,n))
  end do

  call mac_multigrid(mla,rh,phi,fine_flx,alpha,beta,dx,&
                     the_bc_tower,bc_comp,stencil_order,mla%mba%rr,mg_verbose,cg_verbose,umac_norm)

  call mkumac(rh,umac,phi,beta,fine_flx,dx,the_bc_tower,mla%mba%rr,verbose)

  if (use_rhs) then
    call divumac(nlevs,umac,rh,dx,mla%mba%rr,verbose,.false.,divu_rhs)
  else
    call divumac(nlevs,umac,rh,dx,mla%mba%rr,verbose,.false.)
  end if

  if (use_div_coeff) then
    do n = 1,nlevs
       call mult_umac_by_coeff(umac(n,:),div_coeff,div_coeff_half,.false.)
    end do
  end if

  do n = 1, nlevs
     call multifab_destroy(rh(n))
     call multifab_destroy(phi(n))
     call multifab_destroy(alpha(n))
     call multifab_destroy(beta(n))
  end do

  do n = 2,nlevs
     call bndry_reg_destroy(fine_flx(n))
  end do
  deallocate(fine_flx)

  deallocate(rh)
  deallocate(phi)
  deallocate(alpha)
  deallocate(beta)
  deallocate(umac_norm)

  contains

    subroutine divumac(nlevs,umac,rh,dx,ref_ratio,verbose,before,divu_rhs)

      integer        , intent(in   ) :: nlevs
      type(multifab) , intent(inout) :: umac(:,:)
      type(multifab) , intent(inout) :: rh(:)
      real(kind=dp_t), intent(in   ) :: dx(:,:)
      integer        , intent(in   ) :: ref_ratio(:,:)
      integer        , intent(in   ) :: verbose
      logical        , intent(in   ) :: before
      type(multifab ), intent(inout), optional :: divu_rhs(:)

      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: vmp(:,:,:,:) 
      real(kind=dp_t), pointer :: wmp(:,:,:,:) 
      real(kind=dp_t), pointer :: rhp(:,:,:,:) 
      real(kind=dp_t)          :: rhmax
      integer :: i,dm

      dm = rh(nlevs)%dim

      do n = nlevs,2,-1
        do i = 1,dm
          call ml_edge_restriction(umac(n-1,i),umac(n,i),ref_ratio(n-1,:),i)
        end do
      end do

      do n = 1,nlevs
         do i = 1, rh(n)%nboxes
            if ( multifab_remote(rh(n), i) ) cycle
            ump => dataptr(umac(n,1), i)
            vmp => dataptr(umac(n,2), i)
            rhp => dataptr(rh(n)  , i)
            select case (dm)
               case (2)
                 call divumac_2d(ump(:,:,1,1), vmp(:,:,1,1), &
                                 rhp(:,:,1,1), dx(n,:))
               case (3)
                 wmp => dataptr(umac(n,3), i)
                 call divumac_3d(ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                                 rhp(:,:,:,1), dx(n,:))
            end select
         end do
      end do

!     NOTE: the sign convention is because the elliptic solver solves
!            (alpha MINUS del dot beta grad) phi = RHS
!            Here alpha is zero.
             
!     Do rh = divu_rhs - rh
      if (present(divu_rhs)) then
        do n = 1, nlevs
           call multifab_sub_sub(rh(n),divu_rhs(n))
        end do
      end if
!     ... or rh = -rh
      do n = 1, nlevs
         call multifab_mult_mult_s(rh(n),-ONE)
      end do

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

    end subroutine divumac

    subroutine divumac_2d(umac,vmac,rh,dx)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:)
      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:)
      real(kind=dp_t), intent(in   ) ::   dx(:)

      integer :: i,j,nx,ny
     
      nx = size(rh,dim=1)-1

      do j = 0, size(rh,dim=2)-1
      do i = 0, size(rh,dim=1)-1
         rh(i,j) = (umac(i+1,j) - umac(i,j)) / dx(1) + &
                   (vmac(i,j+1) - vmac(i,j)) / dx(2)
      end do
      end do

    end subroutine divumac_2d

    subroutine divumac_3d(umac,vmac,wmac,rh,dx)

      real(kind=dp_t), intent(in   ) :: umac(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: vmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: wmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:, 0:)
      real(kind=dp_t), intent(in   ) :: dx(:)

      integer :: i,j,k,nx,nz

      nx = size(rh,dim=1)-1
      nz = size(rh,dim=3)-1

      do k = 0,size(rh,dim=3)-1
      do j = 0,size(rh,dim=2)-1
      do i = 0,size(rh,dim=1)-1
         rh(i,j,k) = (umac(i+1,j,k) - umac(i,j,k)) / dx(1) + &
                     (vmac(i,j+1,k) - vmac(i,j,k)) / dx(2) + &
                     (wmac(i,j,k+1) - wmac(i,j,k)) / dx(3)
      end do
      end do
      end do

    end subroutine divumac_3d

    subroutine mult_umac_by_coeff(umac,div_coeff,div_coeff_half,do_mult)

      type(multifab) , intent(inout) :: umac(:)
      real(dp_t)     , intent(in   ) :: div_coeff(:)
      real(dp_t)     , intent(in   ) :: div_coeff_half(:)
      logical        , intent(in   ) :: do_mult

      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: vmp(:,:,:,:) 
      real(kind=dp_t), pointer :: wmp(:,:,:,:) 
      integer :: i

      ! Multiply edge velocities by div coeff
      do i = 1, umac(1)%nboxes
         if ( multifab_remote(umac(1), i) ) cycle
         ump => dataptr(umac(1), i)
         vmp => dataptr(umac(2), i)
         select case (umac(1)%dim)
            case (2)
              call mult_by_coeff_2d(ump(:,:,1,1), vmp(:,:,1,1), div_coeff, div_coeff_half, do_mult)
            case (3)
              wmp => dataptr(umac(3), i)
              call mult_by_coeff_3d(ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                                    div_coeff, div_coeff_half, do_mult)
         end select
      end do

    end subroutine mult_umac_by_coeff

    subroutine mult_beta_by_coeff(beta,div_coeff,div_coeff_half)

      type(multifab) , intent(inout) :: beta
      real(dp_t)     , intent(in   ) :: div_coeff(:)
      real(dp_t)     , intent(in   ) :: div_coeff_half(:)

      real(kind=dp_t), pointer :: bp(:,:,:,:) 
      integer :: i

      ! Multiply edge coefficients by div coeff
      do i = 1, beta%nboxes
         if ( multifab_remote(beta, i) ) cycle
         bp => dataptr(beta,i)
         select case (beta%dim)
            case (2)
              call mult_by_coeff_2d(bp(:,:,1,1), bp(:,:,1,2), div_coeff, div_coeff_half, .true.)
            case (3)
              call mult_by_coeff_3d(bp(:,:,:,1), bp(:,:,:,2), bp(:,:,:,3), &
                                    div_coeff, div_coeff_half, .true.)
         end select
      end do

    end subroutine mult_beta_by_coeff

    subroutine mult_by_coeff_2d(umac,vmac,div_coeff,div_coeff_half,do_mult)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:)
      real(dp_t)     , intent(in   ) :: div_coeff(0:)
      real(dp_t)     , intent(in   ) :: div_coeff_half(0:)
      logical        , intent(in   ) :: do_mult

      integer :: i,j,nx,ny
     
      ny = size(umac,dim=2)-2

      if (do_mult) then
        do j = 0,ny-1 
           umac(:,j) = umac(:,j) * div_coeff(j)
        end do
        do j = 0,ny
           vmac(:,j) = vmac(:,j) * div_coeff_half(j)
        end do
      else
        do j = 0,ny-1 
           umac(:,j) = umac(:,j) / div_coeff(j)
        end do
        do j = 0,ny
           vmac(:,j) = vmac(:,j) / div_coeff_half(j)
        end do
      end if

    end subroutine mult_by_coeff_2d

    subroutine mult_by_coeff_3d(umac,vmac,wmac,div_coeff,div_coeff_half,do_mult)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: wmac(-1:,-1:,-1:)
      real(dp_t)     , intent(in   ) :: div_coeff(0:)
      real(dp_t)     , intent(in   ) :: div_coeff_half(0:)
      logical        , intent(in   ) :: do_mult

      integer :: i,j,k,nx,ny,nz
     
      nz = size(umac,dim=3)-2

      if (do_mult) then
        do k = 0,ny 
           umac(:,:,k) = umac(:,:,k) * div_coeff(k)
        end do
        do k = 0,ny 
           vmac(:,:,k) = vmac(:,:,k) * div_coeff(k)
        end do
        do k = 0,ny+1 
           wmac(:,:,k) = wmac(:,:,k) * div_coeff_half(k)
        end do
      else
        do k = 0,ny 
           umac(:,:,k) = umac(:,:,k) / div_coeff(k)
        end do
        do k = 0,ny 
           vmac(:,:,k) = vmac(:,:,k) / div_coeff(k)
        end do
        do k = 0,ny+1 
           wmac(:,:,k) = wmac(:,:,k) / div_coeff_half(k)
        end do
      end if

    end subroutine mult_by_coeff_3d

    subroutine mk_mac_coeffs(nlevs,mla,rho,beta,the_bc_tower)

      integer        , intent(in   ) :: nlevs
      type(ml_layout), intent(inout) :: mla
      type(multifab ), intent(inout) :: rho(:)
      type(multifab ), intent(inout) :: beta(:)
      type(bc_tower ), intent(in   ) :: the_bc_tower
 
      type(box )               :: fine_domain
      real(kind=dp_t), pointer :: bp(:,:,:,:) 
      real(kind=dp_t), pointer :: rp(:,:,:,:) 
      integer :: i,dm,ng,ng_fill

      dm = rho(nlevs)%dim
      ng = rho(nlevs)%ng

      ng_fill = 1
      do n = 2, nlevs
         fine_domain = layout_get_pd(mla%la(n))
         call multifab_fill_ghost_cells(rho(n),rho(n-1),fine_domain, &
                                        ng_fill,mla%mba%rr(n-1,:), &
                                        the_bc_tower%bc_tower_array(n-1)%adv_bc_level_array(0,:,:,:), &
                                        1,dm+1,1)
      end do

      do n = 1, nlevs
         call multifab_fill_boundary(rho(n))
         do i = 1, rho(n)%nboxes
            if ( multifab_remote(rho(n), i) ) cycle
            rp => dataptr(rho(n) , i)
            bp => dataptr(beta(n), i)
            select case (dm)
               case (2)
                 call mk_mac_coeffs_2d(bp(:,:,1,:), rp(:,:,1,1), ng)
               case (3)
                 call mk_mac_coeffs_3d(bp(:,:,:,:), rp(:,:,:,1), ng)
            end select
         end do
      end do

    end subroutine mk_mac_coeffs

    subroutine mk_mac_coeffs_2d(beta,rho,ng)

      integer :: ng
      real(kind=dp_t), intent(inout) :: beta( -1:, -1:,:)
      real(kind=dp_t), intent(inout) ::  rho(-ng:,-ng:)

      integer :: i,j
      integer :: nx,ny
 
      nx = size(beta,dim=1) - 2
      ny = size(beta,dim=2) - 2

      do j = 0,ny-1
      do i = 0,nx
         beta(i,j,1) = TWO / (rho(i,j) + rho(i-1,j))
      end do
      end do

      do j = 0,ny
      do i = 0,nx-1
         beta(i,j,2) = TWO / (rho(i,j) + rho(i,j-1))
      end do
      end do

    end subroutine mk_mac_coeffs_2d

    subroutine mk_mac_coeffs_3d(beta,rho,ng)

      integer :: ng
      real(kind=dp_t), intent(inout) :: beta( -1:, -1:, -1:,:)
      real(kind=dp_t), intent(inout) ::  rho(-ng:,-ng:,-ng:)

      integer :: i,j,k
      integer :: nx,ny,nz
 
      nx = size(beta,dim=1) - 2
      ny = size(beta,dim=2) - 2
      nz = size(beta,dim=3) - 2

      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx
         beta(i,j,k,1) = TWO / (rho(i,j,k) + rho(i-1,j,k))
      end do
      end do
      end do

      do k = 0,nz-1
      do j = 0,ny
      do i = 0,nx-1
         beta(i,j,k,2) = TWO / (rho(i,j,k) + rho(i,j-1,k))
      end do
      end do
      end do

      do k = 0,nz
      do j = 0,ny-1
      do i = 0,nx-1
         beta(i,j,k,3) = TWO / (rho(i,j,k) + rho(i,j,k-1))
      end do
      end do
      end do

    end subroutine mk_mac_coeffs_3d

    subroutine mkumac(rh,umac,phi,beta,fine_flx,dx,the_bc_tower,ref_ratio,verbose)

      type(multifab), intent(inout) :: umac(:,:)
      type(multifab), intent(inout) ::   rh(:)
      type(multifab), intent(in   ) ::  phi(:)
      type(multifab), intent(in   ) :: beta(:)
      type(bndry_reg),intent(in   ) :: fine_flx(2:)
      real(dp_t)    , intent(in   ) :: dx(:,:)
      type(bc_tower), intent(in   ) :: the_bc_tower
      integer       , intent(in   ) :: ref_ratio(:,:)
      integer       , intent(in   ) :: verbose

      integer :: i,dm,nlevs
 
      type(bc_level)           :: bc
      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: vmp(:,:,:,:) 
      real(kind=dp_t), pointer :: wmp(:,:,:,:) 
      real(kind=dp_t), pointer :: php(:,:,:,:) 
      real(kind=dp_t), pointer :: rhp(:,:,:,:) 
      real(kind=dp_t), pointer ::  bp(:,:,:,:) 
      real(kind=dp_t), pointer :: lxp(:,:,:,:) 
      real(kind=dp_t), pointer :: hxp(:,:,:,:) 
      real(kind=dp_t), pointer :: lyp(:,:,:,:) 
      real(kind=dp_t), pointer :: hyp(:,:,:,:) 
      real(kind=dp_t), pointer :: lzp(:,:,:,:) 
      real(kind=dp_t), pointer :: hzp(:,:,:,:) 
      real(kind=dp_t)          :: rhmax

      nlevs = size(rh,dim=1)
      dm = rh(nlevs)%dim

      do n = 1, nlevs
        bc = the_bc_tower%bc_tower_array(n)
        do i = 1, rh(n)%nboxes
          if ( multifab_remote(rh(n), i) ) cycle
          ump => dataptr(umac(n,1), i)
          vmp => dataptr(umac(n,2), i)
          php => dataptr( phi(n), i)
           bp => dataptr(beta(n), i)
          select case (dm)
             case (2)
               if (n > 1) then
                 lxp => dataptr(fine_flx(n)%bmf(1,0), i)
                 hxp => dataptr(fine_flx(n)%bmf(1,1), i)
                 lyp => dataptr(fine_flx(n)%bmf(2,0), i)
                 hyp => dataptr(fine_flx(n)%bmf(2,1), i)
                 call mkumac_2d(ump(:,:,1,1),vmp(:,:,1,1), &
                                php(:,:,1,1), bp(:,:,1,:), &
                                lxp(:,:,1,1),hxp(:,:,1,1),lyp(:,:,1,1),hyp(:,:,1,1), &
                                dx(n,:),bc%ell_bc_level_array(i,:,:,dm+3))
               else 
                 call mkumac_2d_base(ump(:,:,1,1),vmp(:,:,1,1), & 
                                     php(:,:,1,1), bp(:,:,1,:), &
                                     dx(n,:),bc%ell_bc_level_array(i,:,:,dm+3))
               end if
             case (3)
               wmp => dataptr(umac(n,3), i)
               if (n > 1) then
                 lxp => dataptr(fine_flx(n)%bmf(1,0), i)
                 hxp => dataptr(fine_flx(n)%bmf(1,1), i)
                 lyp => dataptr(fine_flx(n)%bmf(2,0), i)
                 hyp => dataptr(fine_flx(n)%bmf(2,1), i)
                 lzp => dataptr(fine_flx(n)%bmf(3,0), i)
                 hzp => dataptr(fine_flx(n)%bmf(3,1), i)
                 call mkumac_3d(ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                                php(:,:,:,1), bp(:,:,:,:), &
                                lxp(:,:,:,1),hxp(:,:,:,1),lyp(:,:,:,1),hyp(:,:,:,1), &
                                lzp(:,:,:,1),hzp(:,:,:,1),dx(n,:),&
                                bc%ell_bc_level_array(i,:,:,dm+3))
               else
                 call mkumac_3d_base(ump(:,:,:,1),vmp(:,:,:,1),wmp(:,:,:,1),& 
                                     php(:,:,:,1), bp(:,:,:,:), dx(n,:), &
                                     bc%ell_bc_level_array(i,:,:,dm+3))
               end if
          end select
        end do
      end do

      do n = nlevs,2,-1
        do i = 1,dm
          call ml_edge_restriction(umac(n-1,i),umac(n,i),ref_ratio(n-1,:),i)
        end do
      end do

    end subroutine mkumac

    subroutine mkumac_2d_base(umac,vmac,phi,beta,dx,press_bc)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy
      integer :: i,j,nx,ny

      nx = size(phi,dim=1) - 2
      ny = size(phi,dim=2) - 2

      if (press_bc(1,1) == BC_NEU) then
         do j = 0,ny-1
            phi(-1,j) = phi(0,j)
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do j = 0,ny-1
            phi(-1,j) = -TWO*phi(0,j) + THIRD * phi(1,j)
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do j = 0,ny-1
            phi(nx,j) = phi(nx-1,j)
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do j = 0,ny-1
            phi(nx,j) = -TWO*phi(nx-1,j) + THIRD * phi(nx-2,j)
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do i = 0,nx-1
            phi(i,-1) = phi(i,0)
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do i = 0,nx-1
            phi(i,-1) = -TWO*phi(i,0) + THIRD * phi(i,1)
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do i = 0,nx-1
            phi(i,ny) = phi(i,ny-1)
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do i = 0,nx-1
            phi(i,ny) = -TWO*phi(i,ny-1) + THIRD * phi(i,ny-2)
         end do
      end if

      do j = 0,ny-1
         do i = 0,nx
            gpx = (phi(i,j) - phi(i-1,j)) / dx(1)
            umac(i,j) = umac(i,j) - beta(i,j,1)*gpx
         end do
      end do

      do i = 0,nx-1
         do j = 0,ny
            gpy = (phi(i,j) - phi(i,j-1)) / dx(2)
            vmac(i,j) = vmac(i,j) - beta(i,j,2)*gpy
         end do
      end do

    end subroutine mkumac_2d_base

    subroutine mkumac_2d(umac,vmac,phi,beta, &
                         lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx, &
                         dx,press_bc)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,0:), lo_y_flx(0:,:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:,0:), hi_y_flx(0:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy
      integer :: i,j,nx,ny

      nx = size(phi,dim=1) - 2
      ny = size(phi,dim=2) - 2

      if (press_bc(1,1) == BC_NEU) then
         do j = 0,ny-1
            phi(-1,j) = phi(0,j)
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do j = 0,ny-1
            phi(-1,j) = -TWO*phi(0,j) + THIRD * phi(1,j)
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do j = 0,ny-1
            phi(nx,j) = phi(nx-1,j)
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do j = 0,ny-1
            phi(nx,j) = -TWO*phi(nx-1,j) + THIRD * phi(nx-2,j)
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do i = 0,nx-1
            phi(i,-1) = phi(i,0)
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do i = 0,nx-1
            phi(i,-1) = -TWO*phi(i,0) + THIRD * phi(i,1)
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do i = 0,nx-1
            phi(i,ny) = phi(i,ny-1)
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do i = 0,nx-1
            phi(i,ny) = -TWO*phi(i,ny-1) + THIRD * phi(i,ny-2)
         end do
      end if

      do j = 0,ny-1
         umac( 0,j) = umac( 0,j) + lo_x_flx(1,j) * dx(1)
         umac(nx,j) = umac(nx,j) + hi_x_flx(1,j) * dx(1)
         do i = 1,nx-1
            gpx = (phi(i,j) - phi(i-1,j)) / dx(1)
            umac(i,j) = umac(i,j) - beta(i,j,1)*gpx
         end do
      end do


      do i = 0,nx-1
         vmac(i, 0) = vmac(i, 0) + lo_y_flx(i,1) * dx(2)
         vmac(i,ny) = vmac(i,ny) + hi_y_flx(i,1) * dx(2)
         do j = 1,ny-1
            gpy = (phi(i,j) - phi(i,j-1)) / dx(2)
            vmac(i,j) = vmac(i,j) - beta(i,j,2)*gpy
         end do
      end do

    end subroutine mkumac_2d

    subroutine mkumac_3d_base(umac,vmac,wmac,phi,beta,dx,press_bc)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: wmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy,gpz
      integer :: i,j,k,nx,ny,nz

      nx = size(phi,dim=1) - 2
      ny = size(phi,dim=2) - 2
      nz = size(phi,dim=3) - 2

      if (press_bc(1,1) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = phi(0,j,k)
         end do
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = -TWO*phi(0,j,k) + THIRD * phi(1,j,k)
         end do
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = phi(nx-1,j,k)
         end do
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = -TWO*phi(nx-1,j,k) + THIRD * phi(nx-2,j,k)
         end do
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = phi(i,0,k)
         end do
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = -TWO*phi(i,0,k) + THIRD * phi(i,1,k)
         end do
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = phi(i,ny-1,k)
         end do
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = -TWO*phi(i,ny-1,k) + THIRD * phi(i,ny-2,k)
         end do
         end do
      end if
      if (press_bc(3,1) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = phi(i,j,0)
         end do
         end do
      else if (press_bc(3,1) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = -TWO*phi(i,j,0) + THIRD * phi(i,j,1)
         end do
         end do
      end if
      if (press_bc(3,2) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = phi(i,j,nz-1)
         end do
         end do
      else if (press_bc(3,2) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = -TWO*phi(i,j,nz-1) + THIRD * phi(i,j,nz-2)
         end do
         end do
      end if

      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx
         gpx = (phi(i,j,k) - phi(i-1,j,k)) / dx(1)
         umac(i,j,k) = umac(i,j,k) - beta(i,j,k,1)*gpx
      end do
      end do
      end do

      do k = 0,nz-1
      do j = 0,ny
      do i = 0,nx-1
         gpy = (phi(i,j,k) - phi(i,j-1,k)) / dx(2)
         vmac(i,j,k) = vmac(i,j,k) - beta(i,j,k,2)*gpy
      end do
      end do
      end do

      do k = 0,nz
      do j = 0,ny-1
      do i = 0,nx-1
         gpz = (phi(i,j,k) - phi(i,j,k-1)) / dx(3)
         wmac(i,j,k) = wmac(i,j,k) - beta(i,j,k,3)*gpz
      end do
      end do
      end do

    end subroutine mkumac_3d_base

    subroutine mkumac_3d(umac,vmac,wmac,phi,beta,lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx, &
                         lo_z_flx,hi_z_flx,dx,press_bc)

      real(kind=dp_t), intent(inout) :: umac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: vmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) :: wmac(-1:,-1:,-1:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,0:,0:), lo_y_flx(0:,:,0:), lo_z_flx(0:,0:,:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:,0:,0:), hi_y_flx(0:,:,0:), hi_z_flx(0:,0:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy,gpz
      integer :: i,j,k,nx,ny,nz

      nx = size(phi,dim=1) - 2
      ny = size(phi,dim=2) - 2
      nz = size(phi,dim=3) - 2

      if (press_bc(1,1) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = phi(0,j,k)
         end do
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = -TWO*phi(0,j,k) + THIRD * phi(1,j,k)
         end do
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = phi(nx-1,j,k)
         end do
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = -TWO*phi(nx-1,j,k) + THIRD * phi(nx-2,j,k)
         end do
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = phi(i,0,k)
         end do
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = -TWO*phi(i,0,k) + THIRD * phi(i,1,k)
         end do
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = phi(i,ny-1,k)
         end do
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = -TWO*phi(i,ny-1,k) + THIRD * phi(i,ny-2,k)
         end do
         end do
      end if
      if (press_bc(3,1) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = phi(i,j,0)
         end do
         end do
      else if (press_bc(3,1) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = -TWO*phi(i,j,0) + THIRD * phi(i,j,1)
         end do
         end do
      end if
      if (press_bc(3,2) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = phi(i,j,nz-1)
         end do
         end do
      else if (press_bc(3,2) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = -TWO*phi(i,j,nz-1) + THIRD * phi(i,j,nz-2)
         end do
         end do
      end if

      do k = 0,nz-1
      do j = 0,ny-1
         umac( 0,j,k) = umac( 0,j,k) + lo_x_flx(1,j,k) * dx(1)
         umac(nx,j,k) = umac(nx,j,k) + hi_x_flx(1,j,k) * dx(1)
         do i = 1,nx-1
            gpx = (phi(i,j,k) - phi(i-1,j,k)) / dx(1)
            umac(i,j,k) = umac(i,j,k) - beta(i,j,k,1)*gpx
         end do
      end do
      end do

      do k = 0,nz-1
      do i = 0,nx-1
         vmac(i, 0,k) = vmac(i, 0,k) + lo_y_flx(i,1,k) * dx(2)
         vmac(i,ny,k) = vmac(i,ny,k) + hi_y_flx(i,1,k) * dx(2)
         do j = 1,ny-1
            gpy = (phi(i,j,k) - phi(i,j-1,k)) / dx(2)
            vmac(i,j,k) = vmac(i,j,k) - beta(i,j,k,2)*gpy
         end do
      end do
      end do

      do j = 0,ny-1
      do i = 0,nx-1
         wmac(i,j, 0) = wmac(i,j, 0) + lo_z_flx(i,j,1) * dx(3)
         wmac(i,j,nz) = wmac(i,j,nz) + hi_z_flx(i,j,1) * dx(3)
         do k = 1,nz-1
            gpz = (phi(i,j,k) - phi(i,j,k-1)) / dx(3)
            wmac(i,j,k) = wmac(i,j,k) - beta(i,j,k,3)*gpz
         end do
      end do
      end do

    end subroutine mkumac_3d

end subroutine macproject

subroutine mac_multigrid(mla,rh,phi,fine_flx,alpha,beta,dx,&
                         the_bc_tower,bc_comp,stencil_order,ref_ratio,mg_verbose,cg_verbose,umac_norm)

  use f2kcli
  use stencil_module
  use coeffs_module
  use mg_module
  use list_box_module
  use itsol_module
  use sparse_solve_module
  use ml_solve_module
  use bl_mem_stat_module
  use box_util_module
  use bl_IO_module

  type(ml_layout),intent(inout) :: mla
  integer        ,intent(in   ) :: stencil_order
  integer        ,intent(in   ) :: ref_ratio(:,:)
  integer        ,intent(in   ) :: mg_verbose, cg_verbose

  real(dp_t), intent(in) :: dx(:,:)
  type(bc_tower), intent(in) :: the_bc_tower
  integer     ,intent(in   ) :: bc_comp
  real(dp_t), intent(in), optional :: umac_norm(:)

  type(layout  ) :: la
  type(boxarray) :: pdv
  type(box     ) :: pd

  type(multifab), allocatable :: coeffs(:)

  type(multifab) , intent(in   ) :: alpha(:), beta(:)
  type(multifab) , intent(inout) ::    rh(:),  phi(:)
  type(bndry_reg), intent(inout) :: fine_flx(2:)

  type( multifab) :: ss
  type(imultifab) :: mm
  type(sparse) :: sparse_object
  type(mg_tower), allocatable :: mgt(:)
  integer        :: i, dm, ns, nlevs
  integer        :: test
  real(dp_t)     :: snrm(2)

  ! MG solver defaults
  integer :: bottom_solver, bottom_max_iter
  integer    :: max_iter
  integer    :: min_width
  integer    :: max_nlevel
  integer    :: verbose
  integer    :: n, nu1, nu2, gamma, cycle, smoother
  integer    :: max_nlevel_in,do_diagnostics
  real(dp_t) :: rel_eps,abs_eps,omega,bottom_solver_eps
  real(dp_t) ::  xa(mla%dim),  xb(mla%dim)
  real(dp_t) :: pxa(mla%dim), pxb(mla%dim)

  !! Defaults:

  nlevs = mla%nlevel
  dm    = mla%dim

  allocate(mgt(nlevs))

  test           = 0

  max_nlevel        = mgt(nlevs)%max_nlevel
  max_iter          = mgt(nlevs)%max_iter
  rel_eps           = mgt(nlevs)%eps
  abs_eps           = mgt(nlevs)%abs_eps
  smoother          = mgt(nlevs)%smoother
  nu1               = mgt(nlevs)%nu1
  nu2               = mgt(nlevs)%nu2
  gamma             = mgt(nlevs)%gamma
  omega             = mgt(nlevs)%omega
  cycle             = mgt(nlevs)%cycle
  bottom_solver     = mgt(nlevs)%bottom_solver
  bottom_solver_eps = mgt(nlevs)%bottom_solver_eps
  bottom_max_iter   = mgt(nlevs)%bottom_max_iter
  min_width         = mgt(nlevs)%min_width
  verbose           = mgt(nlevs)%verbose

! Note: put this here to minimize asymmetries - ASA
  if (nlevs .eq. 1) then
     rel_eps = 1.d-12
  else if (nlevs .eq. 2) then
     rel_eps = 1.d-11
  else
     rel_eps = 1.d-10
  endif

  abs_eps = -1.0_dp_t
  if (present(umac_norm)) then
    do n = 1,nlevs
      abs_eps = max(abs_eps, umac_norm(n) / dx(n,1))
    end do
    abs_eps = rel_eps * abs_eps
  end if

  bottom_solver = 2

  if ( test /= 0 .AND. max_iter == mgt(nlevs)%max_iter ) &
     max_iter = 1000

  ns = 1 + dm*3

  do n = nlevs, 1, -1

     if (n == 1) then
        max_nlevel_in = max_nlevel
     else
        if ( all(ref_ratio(n-1,:) == 2) ) then
           max_nlevel_in = 1
        else if ( all(ref_ratio(n-1,:) == 4) ) then
           max_nlevel_in = 2
        else
           call bl_error("MAC_MULTIGRID: confused about ref_ratio")
        end if
     end if

     pd = layout_get_pd(mla%la(n))

     call mg_tower_build(mgt(n), mla%la(n), pd, &
                         the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp), &
          dh = dx(n,:), &
          ns = ns, &
          smoother = smoother, &
          nu1 = nu1, &
          nu2 = nu2, &
          gamma = gamma, &
          cycle = cycle, &
          omega = omega, &
          bottom_solver = bottom_solver, &
          bottom_max_iter = bottom_max_iter, &
          bottom_solver_eps = bottom_solver_eps, &
          max_iter = max_iter, &
          max_nlevel = max_nlevel_in, &
          min_width = min_width, &
          eps = rel_eps, &
          abs_eps = abs_eps, &
          verbose = mg_verbose, &
          cg_verbose = cg_verbose, &
          nodal = rh(nlevs)%nodal)

  end do

  !! Fill coefficient array

  do n = nlevs,1,-1

     allocate(coeffs(mgt(n)%nlevels))

     la = mla%la(n)
     pd = layout_get_pd(la)

     call multifab_build(coeffs(mgt(n)%nlevels), la, 1+dm, 1)
     call multifab_copy_c(coeffs(mgt(n)%nlevels),1,alpha(n),1, 1,all=.true.)
     call multifab_copy_c(coeffs(mgt(n)%nlevels),2, beta(n),1,dm,all=.true.)

     do i = mgt(n)%nlevels-1, 1, -1
        call multifab_build(coeffs(i), mgt(n)%ss(i)%la, 1+dm, 1)
        call setval(coeffs(i), ZERO, 1, dm+1, all=.true.)
        call coarsen_coeffs(coeffs(i+1),coeffs(i))
     end do

     if (n > 1) then
        xa = HALF*ref_ratio(n-1,:)*mgt(n)%dh(:,mgt(n)%nlevels)
        xb = HALF*ref_ratio(n-1,:)*mgt(n)%dh(:,mgt(n)%nlevels)
     else
        xa = ZERO
        xb = ZERO
     end if

     pxa = ZERO
     pxb = ZERO
     do i = mgt(n)%nlevels, 1, -1
        pdv = layout_boxarray(mgt(n)%ss(i)%la)
        call stencil_fill_cc(mgt(n)%ss(i), coeffs(i), mgt(n)%dh(:,i), &
             pdv, mgt(n)%mm(i), xa, xb, pxa, pxb, pd, stencil_order, &
             the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,dm+3))
     end do

     if ( n == 1 .and. bottom_solver == 3 ) then
        call sparse_build(mgt(n)%sparse_object, mgt(n)%ss(1), &
             mgt(n)%mm(1), mgt(n)%ss(1)%la, stencil_order, mgt(nlevs)%verbose)
     end if
     do i = mgt(n)%nlevels, 1, -1
        call multifab_destroy(coeffs(i))
     end do
     deallocate(coeffs)

  end do

  if (mg_verbose >= 3) then
    do_diagnostics = 1
  else
    do_diagnostics = 0
  end if
  call ml_cc_solve(mla, mgt, rh, phi, fine_flx, &
                   the_bc_tower%bc_tower_array(nlevs)%ell_bc_level_array(0,:,:,dm+3), &
                   stencil_order,ref_ratio,do_diagnostics)

  do n = 1,nlevs
     call multifab_fill_boundary(phi(n))
  end do

  if ( test == 3 ) then
     call sparse_destroy(sparse_object)
  end if
  if ( test > 0 ) then
     call destroy(ss)
     call destroy(mm)
  end if

  do n = 1, nlevs
     call mg_tower_destroy(mgt(n))
  end do
  deallocate(mgt)

end subroutine mac_multigrid

end module macproject_module
