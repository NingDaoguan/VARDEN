module init_module

  use bl_types
  use bl_constants_module
  use bc_module
  use inlet_bc
  use setbc_module
  use define_bc_module
  use multifab_module

  implicit none

contains

   subroutine initdata (u,s,dx,prob_hi,bc,nscal)

      type(multifab) , intent(inout) :: u,s
      real(kind=dp_t), intent(in   ) :: dx(:)
      real(kind=dp_t), intent(in   ) :: prob_hi(:)
      type(bc_level) , intent(in   ) :: bc
      integer        , intent(in   ) :: nscal

      real(kind=dp_t), pointer:: uop(:,:,:,:), sop(:,:,:,:)
      integer :: lo(u%dim),hi(u%dim),ng,dm
      integer :: i,n
      logical :: is_vel

      ng = u%ng
      dm = u%dim
 
      is_vel = .true.
      do i = 1, u%nboxes
         if ( multifab_remote(u, i) ) cycle
         uop => dataptr(u, i)
         sop => dataptr(s, i)
         lo =  lwb(get_box(u, i))
         hi =  upb(get_box(u, i))
         select case (dm)
            case (2)
              call initdata_2d(uop(:,:,1,:), sop(:,:,1,:), lo, hi, ng, dx, prob_hi)
            case (3)
              call initdata_3d(uop(:,:,:,:), sop(:,:,:,:), lo, hi, ng, dx, prob_hi)
         end select
      end do

      call multifab_fill_boundary(u)
      call multifab_fill_boundary(s)

      do i = 1, u%nboxes
         if ( multifab_remote(u, i) ) cycle
         uop => dataptr(u, i)
         sop => dataptr(s, i)
         lo =  lwb(get_box(u, i))
         select case (dm)
            case (2)
              do n = 1,dm
                call setbc_2d(uop(:,:,1,n), lo, ng, bc%adv_bc_level_array(i,:,:,   n),dx,   n)
              end do
              do n = 1,nscal
                call setbc_2d(sop(:,:,1,n), lo, ng, bc%adv_bc_level_array(i,:,:,dm+n),dx,dm+n)
              end do
            case (3)
              do n = 1,dm
                call setbc_3d(uop(:,:,:,n), lo, ng, bc%adv_bc_level_array(i,:,:,   n),dx,   n)
              end do
              do n = 1,nscal
                call setbc_3d(sop(:,:,:,n), lo, ng, bc%adv_bc_level_array(i,:,:,dm+n),dx,dm+n)
              end do
         end select
      end do

   end subroutine initdata

   subroutine initdata_2d (u,s,lo,hi,ng,dx,prob_hi)

      implicit none

      integer, intent(in) :: lo(:), hi(:), ng
      real (kind = dp_t), intent(out) :: u(lo(1)-ng:,lo(2)-ng:,:)  
      real (kind = dp_t), intent(out) :: s(lo(1)-ng:,lo(2)-ng:,:)  
      real (kind = dp_t), intent(in ) :: dx(:)
      real (kind = dp_t), intent(in ) :: prob_hi(:)

!     Local variables
      integer :: i, j, n, jhalf
      real (kind = dp_t) :: x,y,r,cpx,cpy,spx,spy,Pi
      real (kind = dp_t) :: velfact
      real (kind = dp_t) :: ro,r_pert
      real (kind = dp_t) :: r0,denfact

      Pi = 4.0_dp_t*atan(1.0) 
      velfact = 1.0_dp_t

!     ro is the density of air
      ro = 1.2e-3
 
      r_pert = .025

      u = ZERO
      s = ZERO

      jhalf = (lo(2)+hi(2))/2

      if (.false.) then
 
        do j = lo(2), hi(2)
!       y = (float(j)+HALF) * dx(2) / prob_hi(2)
        y = (float(j)+HALF) * dx(2) 
        do i = lo(1), hi(1)
!          x = (float(i)+HALF) * dx(1) / prob_hi(1)
           x = (float(i)+HALF) * dx(1)

!          Initial data for Poiseuille flow.
!          u(i,j,2) = ONE * (x) * (ONE - x)

!          Initial data for vortex-in-a-box
!          if (x .le. 0.5) then
!            spx = sin(Pi*x)
!            cpx = cos(Pi*x)
!          else 
!            spx =  sin(Pi*(1.0-x))
!            cpx = -cos(Pi*(1.0-x))
!          end if
!          if (y .le. 0.5) then
!            spy = sin(Pi*y)
!            cpy = cos(Pi*y)
!          else 
!            spy =  sin(Pi*(1.0-y))
!            cpy = -cos(Pi*(1.0-y))
!          end if

!          spx = sin(Pi*x)
!          spy = sin(Pi*y)
!          cpx = cos(Pi*x)
!          cpy = cos(Pi*y)

!          u(i,j,1) =  TWO*velfact*spy*cpy*spx*spx
!          u(i,j,2) = -TWO*velfact*spx*cpx*spy*spy

           u(i,j,1) = tanh(30.0_dp_T*(0.25_dp_t - abs(y-0.5_dp_t)))
           u(i,j,2) = 0.05d0 * sin(2.0_dp_t*Pi*x)

!          u(i,j,1) = sin(y)
!          u(i,j,2) = cos(x)

           s(i,j,1) = ONE
           r = sqrt((x-HALF)**2 + (y-HALF)**2)
           s(i,j,2) = merge(1.2_dp_t,ONE,r .lt. 0.15)

        enddo
      enddo

      else if (.false.) then

        u = ZERO
        s = ONE
        do j = lo(2), hi(2)
        do i = lo(1), hi(1)
           x = (float(i)+HALF) * dx(1)
           y = (float(j)+HALF) * dx(2)
           if (y.lt.0.50) then
             u(i,j,1) = ONE
           else
             u(i,j,1) = -ONE
           end if
        enddo
        enddo

      else

        u = ZERO
        s = ONE
        r0 = 0.15d0
        denfact = 20.d0
        do j = lo(2), hi(2)
        do i = lo(1), hi(1)
           y = (float(j)+HALF) * dx(2) / prob_hi(2)
           x = (float(i)+HALF) * dx(1) / prob_hi(1)
           r = sqrt((x-HALF)**2 + (y-HALF)**2)
           s(i,j,1) = ONE + HALF*(denfact-ONE)*(ONE-tanh(30.*(r-r0)))
           s(i,j,1) = ONE / s(i,j,1)

        end do
        end do

      end if

!     Impose inflow conditions if grid touches inflow boundary.
!     do i = lo(1), hi(1)
!       x = (float(i)+HALF) * dx(1) / prob_hi(1)
!       u(lo(1)       :hi(1)        ,lo(2)-1,2) = INLET_VY * FOUR*x*(ONE-x)
!     end do

!     Impose inflow conditions if grid touches inflow boundary.
      if (lo(2) .eq. 0) then
         u(lo(1)       :hi(1)        ,lo(2)-1,1) = INLET_VX
         u(lo(1)       :hi(1)        ,lo(2)-1,2) = INLET_VY
         s(lo(1)       :hi(1)        ,lo(2)-1,1) = INLET_DEN
         s(lo(1)       :hi(1)        ,lo(2)-1,2) = INLET_TRA
         s(lo(1)-1:hi(1)+1,lo(2)-1,2) = ONE
      end if

      if (size(s,dim=3).gt.2) then
        do n = 3, size(s,dim=3)
        do j = lo(2), hi(2)
        do i = lo(1), hi(1)
!          s(i,j,n) = ONE
           y = (float(j)+HALF) * dx(2) / prob_hi(2)
           x = (float(i)+HALF) * dx(1) / prob_hi(1)
           r = sqrt((x-HALF)**2 + (y-HALF)**2)
           s(i,j,n) = r
        end do
        end do
        end do
      end if

   end subroutine initdata_2d

   subroutine initdata_3d (u,s,lo,hi,ng,dx,prob_hi)

      implicit none

      integer, intent(in) :: lo(:), hi(:), ng
      real (kind = dp_t), intent(out) :: u(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)  
      real (kind = dp_t), intent(out) :: s(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)  
      real (kind = dp_t), intent(in ) :: dx(:)
      real (kind = dp_t), intent(in ) :: prob_hi(:)
    
!     Local variables
      integer :: i, j, k

      do k=lo(3),hi(3)
         do j=lo(2),hi(2)
            do i=lo(1),hi(1)
               u(i,j,k,1) = ONE
               u(i,j,k,2) = ONE
               u(i,j,k,3) = ONE
               s(i,j,k,1) = ONE
               s(i,j,k,2) = ZERO
            enddo
         enddo
      enddo

      s(3,3,3,2) = ONE
      s(3,3,4,2) = ONE
      s(3,4,3,2) = ONE
      s(3,4,4,2) = ONE
      s(4,3,3,2) = ONE
      s(4,3,4,2) = ONE
      s(4,4,3,2) = ONE
      s(4,4,4,2) = ONE

   end subroutine initdata_3d

   subroutine impose_pressure_bcs(p,mla,mult)

     type(multifab ), intent(inout) :: p(:)
     type(ml_layout), intent(in   ) :: mla
     real(kind=dp_t), intent(in   ) :: mult
 
     type(box)           :: bx,pd
     integer             :: i,n,nlevs
     
     nlevs = size(p,dim=1)

     do n = 1,nlevs
        pd = layout_get_pd(mla%la(n))
        do i = 1, p(n)%nboxes; if ( remote(p(n),i) ) cycle
           bx = get_ibox(p(n),i)
           if (bx%lo(2) == pd%lo(2)) then
             bx%hi(2) = bx%lo(2)
             call setval(p(n),mult,bx)
           end if
        end do
     end do

   end subroutine impose_pressure_bcs

end module init_module