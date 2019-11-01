function lautat(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
                dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
                delvort = delNone(); maxwrite = 100, nround=6)

    # If a restart directory is provided, read in the simulation data
    if startflag == 0
        mat = zeros(0, 13)
        t = 0.
    elseif startflag == 1
        dirvec = readdir()
        dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
        latestTime = maximum(dirresults)
        mat = readdlm("resultsSummary")
        t = mat[end,1]
    else
        throw("invalid start flag, should be 0 or 1")
    end
    mat = mat'

    dt = dtstar*surf.c/surf.uref
    
    # if writeflag is on, determine the timesteps to write at
    if writeflag == 1
        writeArray = Int64[]
        tTot = nsteps*dt
        for i = 1:maxwrite
            tcur = writeInterval*real(i)
            if t > tTot
                break
            else
                push!(writeArray, Int(round(tcur/dt)))
            end
        end
    end

    vcore = 0.02*surf.c

    int_wax = zeros(surf.ndiv)
    int_c = zeros(surf.ndiv)
    int_t = zeros(surf.ndiv)
    
    phi_u = zeros(surf.ndiv)
    phi_l = zeros(surf.ndiv)
    
    bound_circ = 0.

    tevstr = zeros(100)
    tevdist = zeros(100)
    restev = zeros(100,2)
    restev_prev = zeros(2,2)
    
    phi_u_temp = zeros(surf.ndiv)
    phi_l_temp = zeros(surf.ndiv)

    for istep = 1:nsteps

        #Udpate current time
        t = t + dt

        #Update kinematic parameters
        update_kinem(surf, t)
        
        #Update flow field parameters if any
        update_externalvel(curfield, t)
        
        #Update bound vortex positions
        update_boundpos(surf, dt)

        #Update incduced velocities on airfoil
        update_indbound(surf, curfield)
        
        ntev = length(curfield.tev)
        if ntev == 0
            xloc_tev = surf.bnd_x_chord[surf.ndiv] + 0.5*surf.kinem.u*dt*cos(surf.kinem.alpha)
            zloc_tev = surf.bnd_z_chord[surf.ndiv] - 0.5*surf.kinem.u*dt*sin(surf.kinem.alpha)
        else
            xloc_tev = surf.bnd_x_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].x - surf.bnd_x_chord[surf.ndiv])
            zloc_tev = surf.bnd_z_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].z - surf.bnd_z_chord[surf.ndiv])
        end

        #Set up iteration to solve for current time step

        function tev_iter!(FC, J, x)

            #x vector = [aterm; bterm; ate; tevstr]
            
            #FC = zeros(2*surf.naterm+2)
            #           J = zeros(2*surf.naterm+2, 2*surf.naterm+2)
            
            aterm = x[1:surf.naterm]
            bterm = x[surf.naterm+1:2*surf.naterm]
            ate = x[2*surf.naterm+1]
            tevstr = x[2*surf.naterm+2]

            dummyvort = TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.)
            
            uu, wu = ind_vel([dummyvort], surf.bnd_x_u, surf.bnd_z_u)
            ul, wl = ind_vel([dummyvort], surf.bnd_x_l, surf.bnd_z_l)
            
            wlz = 0.5*((surf.wind_u .+ wu).*cos(surf.kinem.alpha) .+ (surf.uind_u .+ uu).*sin(surf.kinem.alpha) .+
                       (surf.wind_l .+ wl)*cos(surf.kinem.alpha) .+ (surf.uind_l .+ ul)*sin(surf.kinem.alpha))
            
            wtz = 0.5*((surf.wind_u .+ wu).*cos(surf.kinem.alpha) .+ (surf.uind_u .+ uu).*sin(surf.kinem.alpha) .-
                       (surf.wind_l .+ wl).*cos(surf.kinem.alpha) .- (surf.uind_l .+ ul).*sin(surf.kinem.alpha))
            
            wtx = 0.5*((surf.uind_u .+ uu).*cos(surf.kinem.alpha) .- (surf.wind_u .+ wu).*sin(surf.kinem.alpha) .+
                       (surf.uind_l .+ ul).*cos(surf.kinem.alpha) .- (surf.wind_l .+ wl).*sin(surf.kinem.alpha))
            
            wlx = 0.5*((surf.uind_u .+ uu).*cos(surf.kinem.alpha) .- (surf.wind_u .+ wu).*sin(surf.kinem.alpha) .-
                       (surf.uind_l .+ ul).*cos(surf.kinem.alpha) .+ (surf.wind_l .+ wl).*sin(surf.kinem.alpha))

            dummyvort = TwoDVort(xloc_tev, zloc_tev, 1., vcore, 0., 0.)
            uu, wu = ind_vel([dummyvort], surf.bnd_x_u, surf.bnd_z_u)
            ul, wl = ind_vel([dummyvort], surf.bnd_x_l, surf.bnd_z_l)

            
            wlz_t = 0.5*(wu.*cos(surf.kinem.alpha) .+ uu.*sin(surf.kinem.alpha) .+
                         wl*cos(surf.kinem.alpha) .+ ul*sin(surf.kinem.alpha))
            wtz_t = 0.5*(wu.*cos(surf.kinem.alpha) .+ uu.*sin(surf.kinem.alpha) .-
                         wl.*cos(surf.kinem.alpha) .- ul.*sin(surf.kinem.alpha))
            wtx_t = 0.5*(uu.*cos(surf.kinem.alpha) .- wu.*sin(surf.kinem.alpha) .+
                         ul.*cos(surf.kinem.alpha) .- wl.*sin(surf.kinem.alpha))
            wlx_t = 0.5*(uu.*cos(surf.kinem.alpha) .- wu.*sin(surf.kinem.alpha) .-
                         ul.*cos(surf.kinem.alpha) .+ wl.*sin(surf.kinem.alpha))
            
            rng = 1:surf.naterm

            Lx = zeros(surf.ndiv); Lz = zeros(surf.ndiv)
            Tx = zeros(surf.ndiv); Tz = zeros(surf.ndiv)
            phi_u_integ = zeros(surf.ndiv)
            phi_l_integ = zeros(surf.ndiv)
            
            i = surf.ndiv-1
            vref_x_u = (surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) - surf.kinem.alphadot*(surf.cam[i] + surf.thick[i])
            vref_x_l = (surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) - surf.kinem.alphadot*(surf.cam[i] - surf.thick[i])
            vref_z = (surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) - (surf.kinem.hdot - curfield.w[1])*cos(surf.kinem.alpha) + surf.kinem.alphadot*(surf.x[i] - surf.pvt*surf.c)
            
            for i = 1:surf.ndiv
                Lx[i] = surf.uref*(sum(aterm[rng]'*sin.(rng*surf.theta[i])) + ate*tan(surf.theta[i]/2))
                Lz[i] = surf.uref*(sum(aterm[rng]'*cos.(rng*surf.theta[i])) + ate)
                Tz[i] = surf.uref*sum(bterm[rng]'*sin.(rng*surf.theta[i]))
                Tx[i] = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))
                if i ==1
                    phi_u_integ[i] = Lz[i] + Tz[i] + wtz[i] + wlz[i]
                    phi_l_integ[i] = -(Lz[i] - Tz[i] - wtz[i] +wlz[i] )
                else
                    phi_u_integ[i] = (Lx[i] + Tx[i] + wtx[i] + wlx[i]) + (surf.cam_slope[i] + surf.thick_slope[i])*(Lz[i] + Tz[i] + wtz[i] + wlz[i])
                    phi_l_integ[i] = (-Lx[i] + Tx[i] + wtx[i] - wlx[i]) + (surf.cam_slope[i] - surf.thick_slope[i])*(Lz[i] - Tz[i] - wtz[i] + wlz[i])
                end    
            end
            
            phi_u_bc = 0; phi_l_bc = 0
            for i = 2:surf.ndiv-1
                phi_u_bc += 0.5*(phi_u_integ[i]/sqrt(1. + (surf.thick_slope[i] + surf.cam_slope[i])^2) + phi_u_integ[i-1]/sqrt(1. + (surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))*sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] + surf.thick[i] - surf.cam[i-1] - surf.thick[i-1])^2)
                phi_l_bc += 0.5*(phi_l_integ[i]/sqrt(1. + (-surf.thick_slope[i] + surf.cam_slope[i])^2) + phi_l_integ[i-1]/sqrt(1. + (-surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))*sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] - surf.thick[i] - surf.cam[i-1] + surf.thick[i-1])^2)
            end

            if !(FC == nothing)
                for i = 2:surf.ndiv-1
                    rhs_l = -(surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) - surf.kinem.alphadot*(surf.x[i] - surf.pvt*surf.c) + (surf.kinem.hdot - curfield.w[1])*cos(surf.kinem.alpha) - wlz[i] + surf.cam_slope[i]*((surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]) + surf.thick_slope[i]*(wlx[i] - surf.kinem.alphadot*surf.thick[i])
                    rhs_nonl = surf.cam_slope[i]*(wlx[i] - surf.kinem.alphadot*surf.thick[i]) + surf.thick_slope[i]*((surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]) - wtz[i]
                    
                    FC[i-1] = Lz[i] - surf.cam_slope[i]*Tx[i] - surf.thick_slope[i]*Lx[i] - rhs_l
                    FC[surf.ndiv+i-3] = Tz[i] - surf.cam_slope[i]*Lx[i] - surf.thick_slope[i]*Tx[i] - rhs_nonl
                    
                end
                
                #Kutta condition
                i = surf.ndiv-1
                qu = sqrt((vref_x_u + Lx[i] + Tx[i] + wlx[i] + wtx[i])^2 + (vref_z + Lz[i] + Tz[i] + wlz[i] + wtz[i])^2)
                ql = sqrt((vref_x_l - Lx[i] + Tx[i] - wlx[i] + wtx[i])^2 + (vref_z + Lz[i] - Tz[i] + wlz[i] - wtz[i])^2)
                FC[2*surf.ndiv-3] = tevstr - 0.5*(qu^2 - ql^2)*dt

                #Kelvin condition
                bc = phi_u_bc - phi_l_bc
                FC[2*surf.ndiv-2] = bc - bound_circ + tevstr
            end

            if !(J == nothing)
                for i = 2:surf.ndiv-1
                    for n = 1:surf.naterm
                        J[i-1,n] = cos(n*surf.theta[i]) - surf.thick_slope[i]*sin(n*surf.theta[i]) 
                        J[i-1,n+surf.naterm] = surf.cam_slope[i]*cos(n*surf.theta[i])
                        J[surf.ndiv+i-3,n] = -surf.cam_slope[i]*sin(n*surf.theta[i])
                        J[surf.ndiv+i-3,surf.naterm+n] = sin(n*surf.theta[i]) + surf.thick_slope[i]*cos(n*surf.theta[i])            
                    end
                    J[i-1,2*surf.naterm+1] = 1. - surf.thick_slope[i]*tan(surf.theta[i]/2)
                    J[surf.ndiv+i-3,2*surf.naterm+1] = -surf.cam_slope[i]*tan(surf.theta[i]/2)
                    J[i-1,2+2*surf.naterm] = -surf.cam_slope[i]*wtx_t[i] - surf.thick_slope[i]*wlx_t[i] + wlz_t[i]
                    J[surf.ndiv+i-3,2+2*surf.naterm] = -surf.cam_slope[i]*wlx_t[i] - surf.thick_slope[i]*wtx_t[i] + wtz_t[i]
                end
                
                #Kutta condition
                i = surf.ndiv-1
                for n = 1:surf.naterm
                    J[2*surf.ndiv-3,n] = -2*dt*(0.5*(vref_x_u + vref_x_l) + Tx[i] + wtx[i])*sin(n*surf.theta[i]) - 2*dt*(Tz[i] + wtz[i])*cos(n*surf.theta[i])
                    J[2*surf.ndiv-3,n+surf.naterm] = 2*dt*(0.5*(vref_x_u - vref_x_l) + Lx[i] + wlx[i])*cos(n*surf.theta[i]) - 2*dt*(vref_z + Lz[i] + wlz[i])*sin(n*surf.theta[i])
                end
                J[2*surf.ndiv-3,2*surf.naterm+1] = -2*dt*(0.5*(vref_x_u + vref_x_l) + Tx[i] + wtx[i])*tan(surf.theta[i]/2) - 2*dt*(Tz[i] + wtz[i])
                J[2*surf.ndiv-3,2*surf.naterm+2] = 1. - 2*dt*(0.5*(vref_x_u + vref_x_l) + Tx[i] + wtx[i])*wlx_t[i] - 2*dt*(0.5*(vref_x_u - vref_x_l) + Lx[i] + wlx[i])*wtx_t[i] - 2*dt*(vref_z + Lz[i] + wlz[i])*wtz_t[i] -2*dt*(Tz[i] + wtz[i])*wlz_t[i]
                
                
                J[2*surf.ndiv-2,:] .= 0.
                #Kelvin condition
                i = 1
                ate_u = tan(surf.theta[i]/2) + (surf.cam_slope[i] + surf.thick_slope[i])
                ate_l = -tan(surf.theta[i]/2) + (surf.cam_slope[i] - surf.thick_slope[i])
                tev_u = wtx_t[i] + wlx_t[i] + (surf.cam_slope[i] + surf.thick_slope[i])*(wlz_t[i] + wtz_t[i])
                tev_l = wtx_t[i] - wlx_t[i] + (surf.cam_slope[i] - surf.thick_slope[i])*(wlz_t[i] - wtz_t[i])
                den_u = sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
                den_l = sqrt(1. + (surf.cam_slope[i] - surf.thick_slope[i])^2)
                ate_u_int = 0; ate_l_int = 0; tev_u_int = 0; tev_l_int = 0

                for i = 2:surf.ndiv-1
                    
                    ate_u_p = ate_u
                    tev_u_p = tev_u
                    ate_l_p = ate_l
                    tev_l_p = tev_l
                    den_u_p = den_u
                    den_l_p = den_l
                    
                    ate_u = tan(surf.theta[i]/2) + (surf.cam_slope[i] + surf.thick_slope[i])
                    ate_l = -tan(surf.theta[i]/2) + (surf.cam_slope[i] - surf.thick_slope[i])
                    tev_u = wtx_t[i] + wlx_t[i] + (surf.cam_slope[i] + surf.thick_slope[i])*(wlz_t[i] + wtz_t[i])
                    tev_l = wtx_t[i] - wlx_t[i] + (surf.cam_slope[i] - surf.thick_slope[i])*(wlz_t[i] - wtz_t[i])
                    den_u = sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
                    den_l = sqrt(1. + (surf.cam_slope[i] - surf.thick_slope[i])^2)
                    
                    ds_u = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] + surf.thick[i] - surf.cam[i-1] - surf.thick[i-1])^2)
                    ds_l = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] - surf.thick[i] - surf.cam[i-1] + surf.thick[i-1])^2)
                    J[2*surf.ndiv-2,2*surf.naterm+1] += 0.5*(ate_u/den_u + ate_u_p/den_u_p)*ds_u 
                    J[2*surf.ndiv-2,2*surf.naterm+1] -= 0.5*(ate_l/den_l + ate_l_p/den_l_p)*ds_l
                    
                    J[2*surf.ndiv-2,2*surf.naterm+2] += 0.5*(tev_u/den_u + tev_u_p/den_u_p)*ds_u
                    J[2*surf.ndiv-2,2*surf.naterm+2] -= 0.5*(tev_l/den_l + tev_l_p/den_l_p)*ds_l
                end                
                J[2*surf.ndiv-2,2*surf.naterm+2] += 1.
                
                for n = 1:surf.naterm
                    i = 1
                    an_u = sin(n*surf.theta[i]) + (surf.cam_slope[i] + surf.thick_slope[i])*cos(n*surf.theta[i])
                    an_l = -sin(n*surf.theta[i]) + (surf.cam_slope[i] - surf.thick_slope[i])*cos(n*surf.theta[i])
                    bn_u = -cos(n*surf.theta[i]) + (surf.cam_slope[i] + surf.thick_slope[i])*sin(n*surf.theta[i])
                    bn_l = -cos(n*surf.theta[i]) - (surf.cam_slope[i] - surf.thick_slope[i])*sin(n*surf.theta[i])
                    den_u = sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
                    den_l = sqrt(1. + (surf.cam_slope[i] - surf.thick_slope[i])^2)
                    
                    an_u_int = 0; an_l_int = 0; bn_u_int = 0; bn_l_int = 0;
                    
                    for i = 2:surf.ndiv-1

                        an_u_p = an_u
                        bn_u_p = bn_u
                        an_l_p = an_l
                        bn_l_p = bn_l
                        den_u_p = den_u
                        den_l_p = den_l
                        
                        an_u = sin(n*surf.theta[i]) + (surf.cam_slope[i] + surf.thick_slope[i])*cos(n*surf.theta[i])
                        an_l = -sin(n*surf.theta[i]) + (surf.cam_slope[i] - surf.thick_slope[i])*cos(n*surf.theta[i])
                        bn_u = -cos(n*surf.theta[i]) + (surf.cam_slope[i] + surf.thick_slope[i])*sin(n*surf.theta[i])
                        bn_l = -cos(n*surf.theta[i]) - (surf.cam_slope[i] - surf.thick_slope[i])*sin(n*surf.theta[i])
                        den_u = sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
                        den_l = sqrt(1. + (surf.cam_slope[i] - surf.thick_slope[i])^2)

                        ds_u = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] + surf.thick[i] - surf.cam[i-1] - surf.thick[i-1])^2)
                        ds_l = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] - surf.thick[i] - surf.cam[i-1] + surf.thick[i-1])^2)
                        J[2*surf.ndiv-2,n] += 0.5*(an_u/den_u + an_u_p/den_u_p)*ds_u
                        J[2*surf.ndiv-2,n+surf.naterm] += 0.5*(bn_u/den_u + bn_u_p/den_u_p)*ds_u
                        J[2*surf.ndiv-2,n] -= 0.5*(an_l/den_l + an_l_p/den_l_p)*ds_l
                        J[2*surf.ndiv-2,n+surf.naterm] -= 0.5*(bn_l/den_l + bn_l_p/den_l_p)*ds_l
                    end
                end
            end
        end
        
        # #Comapre numerical and theoreical jacobians
        # xtest = [ones(2*surf.naterm)*0.001; -0.01; -0.01]
        # FC = zeros(2*surf.ndiv-2)
        # J = zeros(2*surf.ndiv-2,2*surf.ndiv-2)
        # tev_iter!(FC, J, xtest)
        # writedlm("jac_theo.dat", J)

        # FC2 = zeros(2*surf.ndiv-2)
        # J2 = zeros(2*surf.ndiv-2,2*surf.ndiv-2)
        # Jt = zeros(2*surf.ndiv-2,2*surf.ndiv-2) 
        # #Numerical jacobian
        # dx = 1e-4
        # xtest2 = zeros(length(xtest))
        # for j = 1:2*surf.ndiv-2
        #     xtest2[:] .= xtest[:]
        #     xtest2[j] += dx
        #     tev_iter!(FC2, J2, xtest2)
        #     Jt[:,j] = (FC2 - FC)./dx
        # end
        # writedlm("jac_num.dat", Jt)
        
        # error("here")


        
        
        xstart = [surf.aterm; surf.bterm; surf.ate[1]; -0.01]
        
        soln = nlsolve(only_fj!(tev_iter!), xstart, xtol = 1e-6, method=:newton)
        soln = soln.zero
        
        #assign the solution
        surf.aterm[:] = soln[1:surf.naterm]
        surf.bterm[:] = soln[surf.naterm+1:2*surf.naterm]
        surf.ate[1] = soln[2*surf.naterm+1]
        tevstr = soln[2*surf.naterm+2]
        push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))
        
        #println(surf.ate)
        
        #add_indbound_lasttev(surf, curfield)
        update_indbound(surf, curfield)
        
        #Calculate adot
        update_atermdot(surf, dt)
        
        #Set previous values of aterm to be used for derivatives in next time step
        surf.ateprev[1] = surf.ate[1]
        for ia = 1:3
            surf.aprev[ia] = surf.aterm[ia]
        end
        
        #Calculate bound vortex strengths
        update_bv_src(surf)
        
        #Wake rollup
        wakeroll(surf, curfield, dt)

        qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)
        
        #println(cpu[end], " ", cpl[end], 0.5*(qu[end]^2 - ql[end]^2)*dt, " ", tevstr)
        
        #Force calculation
        cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)
        
        bound_circ = phi_u[end-1] - phi_l[end-1]
        
        # write flow details if required
        if writeflag == 1
            if istep in writeArray
                dirname = "$(round(t,sigdigits=nround))"
                writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
            end
        end
        vle = qu[1]
        
        stag = find_stag(surf, qu, ql)
        
        mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
                        cl, cd, cm, cn, cs, bound_circ, stag/surf.c, cpu[1]])

    end
    
    mat = mat'
    
    f = open("resultsSummary", "w")
    Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
    writedlm(f, mat)
    close(f)
    
    mat, surf, curfield
end


# function lautat(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     bound_circ = 0.

#     tevstr = zeros(100)
#     restev = zeros(100)
#     phi_u_temp = zeros(surf.ndiv)
#     phi_l_temp = zeros(surf.ndiv)


#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         #Update LHS and RHS
#         surf, xloc_tev, zloc_tev = update_LHSRHS(surf, curfield, dt, vcore, bound_circ)

#         #soln = surf.LHS \ surf.RHS
#         soln = IterativeSolvers.gmres(surf.LHS, surf.RHS)

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end

#         surf.ate[1] = soln[2*surf.naterm+2]
#         tevstr = soln[2*surf.naterm+1]
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))

#         add_indbound_lasttev(surf, curfield)

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.ateprev[1] = surf.ate[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #Force calculation
#         cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)

#         bound_circ = phi_u[end-1] - phi_l[end-1]

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end
#         vle = qu[1]

#         stag = find_stag(surf, qu, ql)

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cm, cn, cs, bound_circ, stag/surf.c])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end

# function lautat_iter(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                      dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                      delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     bound_circ = 0.

#     tevstr = zeros(100)
#     restev = zeros(100)
#     phi_u_temp = zeros(surf.ndiv)
#     phi_l_temp = zeros(surf.ndiv)


#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Add a TEV with dummy strength
#         place_tev(surf,curfield,dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         #Update LHS and RHS
#         update_RHS(surf, curfield)

#         kelv = KelvinThick(surf, curfield, bound_circ, dt, surf.aterm, surf.bterm)
#         soln = nlsolve(not_in_place(kelv), [-0.01])

#         curfield.tev[end].s = soln.zero[1]
#         soln = surf.LHS \ surf.RHS

#         surf.aterm[:] = soln[1:surf.naterm]
#         surf.bterm[:] = soln[surf.naterm+1:2*surf.naterm]
#         surf.ate[1] = soln[2*surf.naterm+1]


#         #All terms are already updated, no need to do explcitly

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.ateprev[1] = surf.ate[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #Force calculation
#         cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)

#         bound_circ = phi_u[end] - phi_l[end]

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end
#         vle = qu[1]

#         stag = find_stag(surf, qu, ql)

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cm, cn, cs, bound_circ, stag/surf.c])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end

# function lautat_iter_kutta(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                            dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                            delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     bound_circ = 0.

#     tevstr = zeros(100)
#     tevdist = zeros(100)
#     restev = zeros(100,2)
#     restev_prev = zeros(2,2)

#     phi_u_temp = zeros(surf.ndiv)
#     phi_l_temp = zeros(surf.ndiv)

#     theta_te = -2*atan(surf.thick_slope[end])

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         ntev = length(curfield.tev)
#         if ntev == 0
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + 0.5*surf.kinem.u*dt*cos(surf.kinem.alpha)
#             zloc_tev = surf.bnd_z_chord[surf.ndiv] - 0.5*surf.kinem.u*dt*sin(surf.kinem.alpha)
#         else
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].x - surf.bnd_x_chord[surf.ndiv])
#             zloc_tev = surf.bnd_z_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].z - surf.bnd_z_chord[surf.ndiv])
#         end

#         #Set up iteration to solve for current time step

#         function tev_iter(x)

#             #x vector = [aterm; bterm; ate; tevstr]

#             FC = zeros(2*surf.naterm+2)

#             aterm = x[1:surf.naterm]
#             bterm = x[surf.naterm+1:2*surf.naterm]
#             ate = x[2*surf.naterm+1]
#             tevstr = x[2*surf.naterm+2]

#             dummyvort = TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.)

#             uu, wu = ind_vel([dummyvort], surf.bnd_x_u, surf.bnd_z_u)
#             ul, wl = ind_vel([dummyvort], surf.bnd_x_l, surf.bnd_z_l)

#             wlz = 0.5*((surf.wind_u .+ wu).*cos(surf.kinem.alpha) .+ (surf.uind_u .+ uu).*sin(surf.kinem.alpha) .+
#                        (surf.wind_l .+ wl)*cos(surf.kinem.alpha) .+ (surf.uind_l .+ ul)*sin(surf.kinem.alpha))

#             wtz = 0.5*((surf.wind_u .+ wu).*cos(surf.kinem.alpha) .+ (surf.uind_u .+ uu).*sin(surf.kinem.alpha) .-
#                        (surf.wind_l .+ wl).*cos(surf.kinem.alpha) .- (surf.uind_l .+ ul).*sin(surf.kinem.alpha))

#             wtx = 0.5*((surf.uind_u .+ uu).*cos(surf.kinem.alpha) .- (surf.wind_u .+ wu).*sin(surf.kinem.alpha) .+
#                        (surf.uind_l .+ ul).*cos(surf.kinem.alpha) .- (surf.wind_l .+ wl).*sin(surf.kinem.alpha))

#             wlx = 0.5*((surf.uind_u .+ uu).*cos(surf.kinem.alpha) .- (surf.wind_u .+ wu).*sin(surf.kinem.alpha) .-
#                        (surf.uind_l .+ ul).*cos(surf.kinem.alpha) .+ (surf.wind_l .+ wl).*sin(surf.kinem.alpha))

#             rng = 1:surf.naterm

#             #Calcualte phi alongside for kelvin condition
#             i = 1
#             Lx = surf.uref*(sum(aterm[rng]'*sin.(rng*surf.theta[i])) + ate*tan(surf.theta[i]/2))
#             Lz = surf.uref*(sum(aterm[rng]'*cos.(rng*surf.theta[i])) + ate)
#             Tz = surf.uref*sum(bterm[rng]'*sin.(rng*surf.theta[i]))
#             Tx = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))

#             uphi_u = Lx + Tx + wtx[i] + wlx[i]
#             wphi_u = Lz + Tz + wtz[i] + wlz[i]
#             uphi_l = -Lx + Tx + wtx[i] - wlx[i]
#             wphi_l = Lz - Tz - wtz[i] +wlz[i] 

#             uphi_u_p = 0.
#             wphi_u_p = 0.
#             uphi_l_p = 0.
#             wphi_l_p = 0.

#             phi_u_bc = 0.
#             phi_l_bc = 0.

#             for i = 2:surf.ndiv-1

#                 uphi_u_p = uphi_u
#                 wphi_u_p = wphi_u
#                 uphi_l_p = uphi_l
#                 wphi_l_p = wphi_l

#                 Lx = surf.uref*(sum(aterm[rng]'*sin.(rng*surf.theta[i])) + ate*tan(surf.theta[i]/2))
#                 Lz = surf.uref*(sum(aterm[rng]'*cos.(rng*surf.theta[i])) + ate)
#                 Tz = surf.uref*sum(bterm[rng]'*sin.(rng*surf.theta[i]))
#                 Tx = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))

#                 uphi_u = Lx + Tx + wtx[i] + wlx[i]
#                 wphi_u = Lz + Tz + wtz[i] + wlz[i]
#                 uphi_l = -Lx + Tx + wtx[i] - wlx[i]
#                 wphi_l = Lz - Tz - wtz[i] + wlz[i] 

#                 rhs_l = -(surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) - surf.kinem.alphadot*(surf.x[i] - surf.pvt*surf.c) + (surf.kinem.hdot - curfield.w[1])*cos(surf.kinem.alpha) - wlz[i] + surf.cam_slope[i]*((surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]) + surf.thick_slope[i]*(wlx[i] - surf.kinem.alphadot*surf.thick[i])
#                 rhs_nonl = surf.cam_slope[i]*(wlx[i] - surf.kinem.alphadot*surf.thick[i]) + surf.thick_slope[i]*((surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]) - wtz[i]

#                 FC[i-1] = Lz - surf.cam_slope[i]*Tx - surf.thick_slope[i]*Lx - rhs_l
#                 FC[surf.ndiv+i-3] = Tz - surf.cam_slope[i]*Lx - surf.thick_slope[i]*Tx - rhs_nonl

#                 ds = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] + surf.thick[i] - surf.cam[i-1] - surf.thick[i-1])^2)
#                 if i == 2
#                     val1 = 0.5*(uphi_u/sqrt(1. + (surf.thick_slope[i] + surf.cam_slope[i])^2))
#                     val2 = 0.5*(wphi_u*(surf.thick_slope[i] + surf.cam_slope[i])/sqrt(1. + (surf.thick_slope[i] + surf.cam_slope[i])^2) + wphi_u_p)  
#                 else
#                     val1 = 0.5*(uphi_u/sqrt(1. + (surf.thick_slope[i] + surf.cam_slope[i])^2) + uphi_u_p/sqrt(1. + (surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))  
#                     val2 = 0.5*(wphi_u*(surf.thick_slope[i] + surf.cam_slope[i])/sqrt(1. + (surf.thick_slope[i] + surf.cam_slope[i])^2) + wphi_u_p*(surf.thick_slope[i-1] + surf.cam_slope[i-1])/sqrt(1. + (surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))  
#                 end
#                 phi_u_bc += val1*ds + val2*ds

#                 ds = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] - surf.thick[i] - surf.cam[i-1] + surf.thick[i-1])^2)
#                 if i == 2
#                     val1 = 0.5*(uphi_l/sqrt(1. + (-surf.thick_slope[i] + surf.cam_slope[i])^2))
#                     val2 = 0.5*(wphi_l*(-surf.thick_slope[i] + surf.cam_slope[i])/sqrt(1. + (-surf.thick_slope[i] + surf.cam_slope[i])^2) + wphi_l_p)
#                 else
#                     val1 = 0.5*(uphi_l/sqrt(1. + (-surf.thick_slope[i] + surf.cam_slope[i])^2) + uphi_l_p/sqrt(1. + (-surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))  
#                     val2 = 0.5*(wphi_l*(-surf.thick_slope[i] + surf.cam_slope[i])/sqrt(1. + (-surf.thick_slope[i] + surf.cam_slope[i])^2) + wphi_l_p*(-surf.thick_slope[i-1] + surf.cam_slope[i-1])/sqrt(1. + (-surf.thick_slope[i-1] + surf.cam_slope[i-1])^2))  
#                 end
#                 phi_l_bc += val1*ds + val2*ds

#             end

#             #LE nonlifting equation
#             i = 1
#             Tx = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))
#             rhs_nonl = (surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]
#             #    FC[2*surf.ndiv-3] = -Tx - rhs_nonl 

#             #TE lifting equation
#             i = surf.ndiv
#             Lz = surf.uref*(sum(aterm[rng]'*cos.(rng*surf.theta[i])) + ate)
#             Tx = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))
#             rhs_l = -(surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) - surf.kinem.alphadot*(surf.x[i] - surf.pvt*surf.c) + (surf.kinem.hdot - curfield.w[1])*cos(surf.kinem.alpha) - wlz[i] + surf.cam_slope[i]*((surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) + wtx[i] - surf.kinem.alphadot*surf.cam[i]) 
#             #   FC[2*surf.ndiv-2] = Lz - surf.cam_slope[i]*Tx - rhs_l

#             i = surf.ndiv-1
#             Lx = surf.uref*(sum(aterm[rng]'*sin.(rng*surf.theta[i])) + ate*tan(surf.theta[i]/2))
#             Lz = surf.uref*(sum(aterm[rng]'*cos.(rng*surf.theta[i])) + ate)
#             Tz = surf.uref*sum(bterm[rng]'*sin.(rng*surf.theta[i]))
#             Tx = -surf.uref*sum(bterm[rng]'*cos.(rng*surf.theta[i]))

#             #Kutta condition
#             vref_x = (surf.kinem.u + curfield.u[1])*cos(surf.kinem.alpha) + (surf.kinem.hdot - curfield.w[1])*sin(surf.kinem.alpha) 
#             qu = vref_x + Lx + Tx + wlx[i] + wtx[i]
#             ql = vref_x - Lx + Tx - wlx[i] + wtx[i]
#             #FC[2*surf.ndiv-1] = tevstr - 2*surf.uref^2*dt*ate*(sum((-1).^rng'*bterm[rng]) + vref_x + wtx[surf.ndiv])
#             FC[2*surf.ndiv-3] = tevstr - 0.5*(qu^2 - ql^2)*dt

#             bc = phi_u_bc - phi_l_bc

#             #Kelvin condition
#             FC[2*surf.ndiv-2] = bc - bound_circ + tevstr

#             #println(x)

#             return FC

#         end

#         xstart = [surf.aterm; surf.bterm; -0.01; -0.01]

#         soln = nlsolve(tev_iter, xstart, ftol = 1e-8, show_trace=true, iterations=10, method=:newton)
#         #soln = optimize(tev_iter, xstart, Dogleg(LeastSquaresOptim.LSMR()), f_tol=1e-4)
#         #soln = fsolve(tev_iter!, xstart)
#         soln = soln.zero
#         #soln = soln.minimizer


#         #assign the solution
#         surf.aterm[:] = soln[1:surf.naterm]
#         surf.bterm[:] = soln[surf.naterm+1:2*surf.naterm]
#         surf.ate[1] = soln[2*surf.naterm+1]
#         tevstr = soln[2*surf.naterm+2]
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))

#         #println(surf.ate)

#         #add_indbound_lasttev(surf, curfield)
#         update_indbound(surf, curfield)

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.ateprev[1] = surf.ate[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #println(cpu[end], " ", cpl[end], 0.5*(qu[end]^2 - ql[end]^2)*dt, " ", tevstr)

#         #Force calculation
#         cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)

#         bound_circ = phi_u[end-1] - phi_l[end-1]

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end
#         vle = qu[1]

#         stag = find_stag(surf, qu, ql)

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cm, cn, cs, bound_circ, stag/surf.c])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end



# function lautat_iter_dblwk(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500, dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                            delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     bound_circ = 0.

#     tevstr = zeros(100)
#     restev = zeros(100)
#     phi_u_temp = zeros(surf.ndiv)
#     phi_l_temp = zeros(surf.ndiv)


#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         zbl_u = surf.bnd_z_l[surf.ndiv] + 0.01
#         zbl_l = surf.bnd_z_l[surf.ndiv] - 0.01

#         ntev = length(curfield.tev)
#         if ntev == 0
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + 0.5*surf.kinem.u*dt
#             zloc_tev = zbl_l
#         else
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].x - surf.bnd_x_chord[surf.ndiv])
#             zloc_tev = zbl_l + (1. /3.)*(curfield.tev[ntev].z - zbl_l)
#         end
#         nlev = length(curfield.lev)
#         if nlev == 0
#             xloc_lev = surf.bnd_x_chord[surf.ndiv] + 0.5*surf.kinem.u*dt
#             zloc_lev = zbl_u
#         else
#             xloc_lev = surf.bnd_x_chord[surf.ndiv] + (1. /3.)*(curfield.lev[nlev].x - surf.bnd_x_chord[surf.ndiv])
#             zloc_lev = zbl_u + (1. /3.)*(curfield.lev[nlev].z - zbl_u)
#         end

#         #Iteratively solve for TE strength

#         #No need to update LHS
#         tevstr[1] = -0.1
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[1], vcore, 0., 0.))
#         add_indbound_lasttev(surf, curfield)
#         qu, ql = calc_edgeVel(surf, [curfield.u[1]; curfield.w[1]])
#         levstr = 0.5*qu[surf.ndiv]^2*dt
#         push!(curfield.lev, TwoDVort(xloc_lev, zloc_lev, levstr[1], vcore, 0., 0.))
#         add_indbound_lastlev(surf, curfield)

#         #Update RHS vector
#         update_RHS(surf, curfield)
#         soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end

#         phi_u_temp, phi_l_temp  = calc_phi(surf)
#         restev[1] = (phi_u_temp - phi_l_temp) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[1] + levstr

#         minus_indbound_lasttev(surf, curfield)
#         pop!(curfield.tev)
#         minus_indbound_lastlev(surf, curfield)
#         pop!(curfield.lev)

#         tevstr[2] = 0.1
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[2], vcore, 0., 0.))
#         add_indbound_lasttev(surf, curfield)
#         qu, ql = calc_edgeVel(surf, [curfield.u[1]; curfield.w[1]])
#         levstr = 0.5*qu[surf.ndiv]^2*dt
#         push!(curfield.lev, TwoDVort(xloc_lev, zloc_lev, levstr[1], vcore, 0., 0.))
#         add_indbound_lastlev(surf, curfield)

#         #Update RHS vector
#         update_RHS(surf, curfield)
#         soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]
#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end

#         phi_u_temp, phi_l_temp  = calc_phi(surf)
#         restev[2] = (phi_u_temp - phi_l_temp) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[2] + levstr

#         iter = 2

#         while restev[iter] > 1e-6
#             iter += 1
#             minus_indbound_lasttev(surf, curfield)
#             pop!(curfield.tev)
#             minus_indbound_lastlev(surf, curfield)
#             pop!(curfield.lev)
#             tevstr[iter] = tevstr[iter-1] - restev[iter-1]*(tevstr[iter-1] - tevstr[iter-2])/(restev[iter-1] - restev[iter-2])
#             push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[iter], vcore, 0., 0.))
#             add_indbound_lasttev(surf, curfield)
#             qu, ql = calc_edgeVel(surf, [curfield.u[1]; curfield.w[1]])
#             levstr = 0.5*qu[surf.ndiv]^2*dt
#             push!(curfield.lev, TwoDVort(xloc_lev, zloc_lev, levstr[1], vcore, 0., 0.))
#             add_indbound_lastlev(surf, curfield)

#             #Update RHS vector
#             update_RHS(surf, curfield)
#             soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]

#             #Assign the solution
#             for i = 1:surf.naterm
#                 surf.aterm[i] = soln[i]
#                 surf.bterm[i] = soln[i+surf.naterm]
#             end

#             phi_u_temp, phi_l_temp  = calc_phi(surf)
#             restev[iter] = (phi_u_temp - phi_l_temp) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[iter] + levstr

#         end

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #Force calculation
#         cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)

#         bound_circ = phi_u[end] - phi_l[end]

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end
#         vle = qu[1]

#         stag = find_stag(surf, qu, ql)

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cm, cn, cs, bound_circ, stag/surf.c])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end


# function lautat(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     bound_circ = 0.

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         #Set up the matrix problem
#         surf, xloc_tev, zloc_tev = update_LHSRHS(surf, curfield, dt, vcore, bound_circ)

#         #Now solve the matrix problem
#         soln = surf.LHS \ surf.RHS

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end
#         tevstr = soln[2*surf.naterm+1]
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Update induced velocities to include effect of last shed vortex
#         add_indbound_lasttev(surf, curfield)
#         #update_indbound(surf, curfield)

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #Force calculation
#         cn, cs, cl, cd, cm = calc_forces(surf, cpu, cpl)

#         bound_circ = phi_u[end] - phi_l[end]

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end
#         vle = qu[1]

#         if vle > 0.
#             stag = surf.x[argmin(ql)]
#         else
#             stag = surf.x[argmin(qu)]
#         end

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cm, cn, cs, bound_circ, stag])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "Vle \t", "Cl \t", "Cd \t", "Cm \t", "Cn \t", "Cs \t", "bc \t", "xs \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end




# function lautat(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     uind_up = zeros(surf.ndiv)
#     wind_up = zeros(surf.ndiv)
#     uind_lp = zeros(surf.ndiv)
#     wind_lp = zeros(surf.ndiv)

#     bound_circ = 0.

#     tevstr = zeros(100)
#     restev = zeros(100)
#     phi_u_temp = zeros(surf.ndiv)
#     phi_l_temp = zeros(surf.ndiv)

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)


#         ntev = length(curfield.tev)

#         if ntev == 0
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + 0.5*surf.kinem.u*dt
#             zloc_tev = surf.bnd_z_chord[surf.ndiv]
#         else
#             xloc_tev = surf.bnd_x_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].x - surf.bnd_x_chord[surf.ndiv])
#             zloc_tev = surf.bnd_z_chord[surf.ndiv] + (1. /3.)*(curfield.tev[ntev].z - surf.bnd_z_chord[surf.ndiv])
#         end
#         #Iteratively solve for TE strength

#         #No need to update LHS
#         tevstr[1] = -0.1

#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[1], vcore, 0., 0.))
#         update_indbound(surf, curfield)
#         #Update RHS vector
#         update_thickRHS(surf, curfield)
#         soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end

#         qu, ql, phi_u_temp, phi_l_temp, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)
#         restev[1] = (phi_u_temp[surf.ndiv] - phi_l_temp[surf.ndiv]) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[1]

#         pop!(curfield.tev)
#         tevstr[2] = 0.1
#         #-((phi_u_temp[surf.ndiv] - phi_l_temp[surf.ndiv]) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]))
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[2], vcore, 0., 0.))
#         update_indbound(surf, curfield)
#         #Update RHS vector
#         update_thickRHS(surf, curfield)
#         soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]
#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end

#         qu, ql, phi_u_temp, phi_l_temp, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)
#         restev[2] = (phi_u_temp[surf.ndiv] - phi_l_temp[surf.ndiv]) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[2]

#         iter = 2

#         while restev[iter] > 1e-6
#             iter += 1
#             pop!(curfield.tev)
#             tevstr[iter] = tevstr[iter-1] - restev[iter-1]*(tevstr[iter-1] - tevstr[iter-2])/(restev[iter-1] - restev[iter-2])
#             push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr[iter], vcore, 0., 0.))

#             update_indbound(surf, curfield)
#             #Update RHS vector
#             update_thickRHS(surf, curfield)
#             soln = surf.LHS[1:surf.ndiv*2-4, 1:surf.naterm*2] \ surf.RHS[1:surf.ndiv*2-4]

#             #Assign the solution
#             for i = 1:surf.naterm
#                 surf.aterm[i] = soln[i]
#                 surf.bterm[i] = soln[i+surf.naterm]
#             end

#             qu, ql, phi_u_temp, phi_l_temp, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#             restev[iter] = (phi_u_temp[surf.ndiv] - phi_l_temp[surf.ndiv]) - (phi_u[surf.ndiv] - phi_l[surf.ndiv]) + tevstr[iter]

#             #println(istep, " " , iter, " ", tevstr[iter], " " , restev[iter], " ",  phi_u[end], " ", phi_l[end], " ", phi_u_temp[end], phi_l_temp[end])

#         end


#         #println(istep, " " , iter, " ", tevstr[iter], " ", restev[iter])
#         #error("here")

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Update the bound circulation value
#         bound_circ = surf.LHS[2*surf.ndiv-3]*[surf.aterm;surf.bterm;0.]

#         #Update induced velocities to include effect of last shed vortex
#         update_indbound(surf, curfield)

#         uind_up[:] = surf.uind_u[:]
#         wind_up[:] = surf.wind_u[:]
#         uind_lp[:] = surf.uind_l[:]
#         wind_lp[:] = surf.wind_l[:]

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         #Force calculation
#         cnc, cnnc, cn, cs, cl, cd, int_wax, int_c, int_t = calc_forces(surf, int_wax, int_c, int_t, dt)
#         #println(phi_u)
#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)

#         #Calcualte forces from pressure
#         ds = sqrt((surf.x[2] - surf.x[1])^2 + (surf.cam[2] + surf.thick[2] - surf.cam[1] - surf.thick[1])^2)
#         vert = 1. /sqrt(1. + (surf.cam_slope[2] + surf.thick_slope[2])^2)
#         hor = -(surf.cam_slope[2] + surf.thick_slope[2])/sqrt(1. + (surf.cam_slope[2] + surf.thick_slope[2])^2)
#         cs = 0.5*(cpu[2]*hor + cpu[1])*ds
#         cn = -0.5*(cpu[2]*vert)*ds
#         ds = sqrt((surf.x[2] - surf.x[1])^2 + (surf.cam[2] - surf.thick[2] - surf.cam[1] + surf.thick[1])^2)
#         vert = -1. /sqrt(1. + (surf.cam_slope[2] - surf.thick_slope[2])^2)
#         hor = (surf.cam_slope[2] - surf.thick_slope[2])/sqrt(1. + (surf.cam_slope[2] - surf.thick_slope[2])^2)
#         cs += 0.5*(cpl[2]*hor + cpl[1])*ds
#         cn -= 0.5*(cpl[2]*vert)*ds

#         for i = 3:surf.ndiv
#             ds = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] + surf.thick[i] - surf.cam[i-1] - surf.thick[i-1])^2)
#             vert = 1. /sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
#             vert_p = 1. /sqrt(1. + (surf.cam_slope[i-1] + surf.thick_slope[i-1])^2)
#             hor = -(surf.cam_slope[i] + surf.thick_slope[i])/sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
#             hor_p = -(surf.cam_slope[i-1] + surf.thick_slope[i-1])/sqrt(1. + (surf.cam_slope[i-1] + surf.thick_slope[i-1])^2)

#             cs += 0.5*(cpu[i]*hor + cpu[i-1]*hor_p)*ds
#             cn -= 0.5*(cpu[i]*vert + cpu[i-1]*vert_p)*ds

#             ds = sqrt((surf.x[i] - surf.x[i-1])^2 + (surf.cam[i] - surf.thick[i] - surf.cam[i-1] + surf.thick[i-1])^2)
#             vert = -1. /sqrt(1. + (surf.cam_slope[i] - surf.thick_slope[i])^2)
#             vert_p = -1. /sqrt(1. + (surf.cam_slope[i-1] - surf.thick_slope[i-1])^2)
#             hor = (surf.cam_slope[i] - surf.thick_slope[i])/sqrt(1. + (surf.cam_slope[i] + surf.thick_slope[i])^2)
#             hor_p = (surf.cam_slope[i-1] - surf.thick_slope[i-1])/sqrt(1. + (surf.cam_slope[i-1] - surf.thick_slope[i-1])^2)

#             cs += 0.5*(cpl[i]*hor + cpl[i-1]*hor_p)*ds
#             cn -= 0.5*(cpl[i]*vert + cpl[i-1]*vert_p)*ds
#         end
#         cl = cn*cos(surf.kinem.alpha) + cs*sin(surf.kinem.alpha)
#         cd = cn*sin(surf.kinem.alpha) - cs*cos(surf.kinem.alpha)

#         #println(phi_l)
#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end

#         #plot(surf.x, qu)


#         #LE velocity and stagnation point location
#         #vle = (surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) + (curfield.w[1] - surf.kinem.hdot)*cos(surf.kinem.alpha) - surf.kinem.alphadot*surf.pvt*surf.c + sum(surf.aterm) + surf.wind_u[1]  


#         vle = qu[1]

#         # if vle > 0.
#         #     qspl = Spline1D(surf.x, ql)
#         #     stag = try
#         #         roots(qspl, maxn=1)[1]
#         #     catch
#         #         0.
#         #     end
#         # else
#         #     qspl = Spline1D(surf.x, qu)
#         #     stag = try
#         #         roots(qspl, maxn=1)[1]
#         #     catch
#         #         0.
#         #     end
#         # end

#          if vle > 0.
#              stag = surf.x[argmin(ql)]
#          else
#              stag = surf.x[argmin(qu)]
#          end
#              # else
#         #     qspl = Spline1D(surf.x, qu)
#         #     stag = try
#         #         roots(qspl, maxn=1)[1]
#         #     catch
#         #         0.
#         #     end
#         # end



#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cnc, cs, cn, phi_u[end]-phi_l[end], stag])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "A0 \t", "Cl \t", "Cd \t", "Cm \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end


# function wkg_lautat(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         #Set up the matrix problem
#         surf, xloc_tev, zloc_tev = wkg_update_thickLHS(surf, curfield, dt, vcore)

#         #Construct RHS vector
#         wkg_update_thickRHS(surf, curfield)

#         #Now solve the matrix problem
#         #soln = surf.LHS[[1:surf.ndiv*2-3;2*surf.ndiv-1], 1:surf.naterm*2+2] \ surf.RHS[[1:surf.ndiv*2-3; 2*surf.ndiv-1]]
#         soln = surf.LHS[1:surf.ndiv*2-3, 1:surf.naterm*2+1] \ surf.RHS[1:surf.ndiv*2-3]

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end
#         tevstr = soln[2*surf.naterm+1]*surf.uref*surf.c
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Update induced velocities to include effect of last shed vortex
#         update_indbound(surf, curfield)

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         #Force calculation
#         cnc, cnnc, cn, cs, cl, cd, int_wax, int_c, int_t = calc_forces(surf, int_wax, int_c, int_t, dt)
#         #println(phi_u)
#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)
#         #println(phi_l)
#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end

#         #LE velocity and stagnation point location
#         #vle = (surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) + (curfield.w[1] - surf.kinem.hdot)*cos(surf.kinem.alpha) - surf.kinem.alphadot*surf.pvt*surf.c + sum(surf.aterm) + surf.wind_u[1]  


#         vle = qu[1]

#         if vle > 0.
#             qspl = Spline1D(surf.x, ql)
#             stag = try
#                 roots(qspl, maxn=1)[1]
#             catch
#                 0.
#             end
#         else
#             qspl = Spline1D(surf.x, qu)
#             stag = try
#                 roots(qspl, maxn=1)[1]
#             catch
#                 0.
#             end
#         end

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cnc, cnnc, cn, cs, stag])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "A0 \t", "Cl \t", "Cd \t", "Cm \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end





# function lautat_kutta(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 12)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     phi_u = zeros(surf.ndiv)
#     phi_l = zeros(surf.ndiv)

#     RHSvort = zeros(2*surf.ndiv-3)

#     qu = zeros(surf.ndiv)
#     ql = zeros(surf.ndiv)

#     tol_iter = 1e-6

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         res = 1
#         nlev = length(curfield.lev)
#         a_iter = zeros(surf.naterm)
#         b_iter = zeros(surf.naterm)
#         a_iter[:] = surf.aterm[:]
#         b_iter[:] = surf.bterm[:]

#         #Iterate for solution
#         function soln_iter()
#             #Add vortex on upper surface
#             if nlev == 0
#                 xloc_lev = surf.bnd_x_u[surf.ndiv] + 0.5*surf.kinem.u*dt
#                 zloc_lev =  surf.bnd_z_u[surf.ndiv]
#             else
#                 xloc_lev = surf.bnd_x_u[surf.ndiv] + (1. /3.)*(curfield.lev[nlev].x - surf.bnd_x_u[surf.ndiv])
#                 zloc_lev = surf.bnd_z_u[surf.ndiv]+(1. /3.)*(curfield.lev[nlev].z - surf.bnd_z_u[surf.ndiv])
#             end

#             qu, ql = calc_edgeVel_newFourier(surf, [curfield.u[1]; curfield.w[1]], a_iter, b_iter)
#             levstr = 0.5*qu[end]^2*dt
#             u_vort = TwoDVort(xloc_lev, zloc_lev, levstr, vcore, 0., 0.)

#             ind_new_u_u, ind_new_w_u = ind_vel([u_vort], surf.bnd_x_u, surf.bnd_z_u)
#             ind_new_u_l, ind_new_w_l = ind_vel([u_vort], surf.bnd_x_l, surf.bnd_z_l)

#             surf.uind_u[:] += ind_new_u_u[:]
#             surf.wind_u[:] += ind_new_w_u[:]
#             surf.uind_l[:] += ind_new_u_l[:]
#             surf.wind_l[:] += ind_new_w_l[:]

#             #Set up the matrix problem
#             surf, xloc_tev, zloc_tev = update_thickLHS_kutta(surf, curfield, dt, vcore)

#             #Construct RHS vector
#             update_thickRHS(surf, curfield)

#         RHSvort[2*surf.ndiv-3] = -100*levstr/(surf.uref*surf.c)

#         surf.uind_u[:] -= ind_new_u_u[:]
#         surf.wind_u[:] -= ind_new_w_u[:]
#         surf.uind_l[:] -= ind_new_u_l[:]
#         surf.wind_l[:] -= ind_new_w_l[:]


#         #Now solve the matrix problem
#         #soln = surf.LHS[[1:surf.ndiv*2-3;2*surf.ndiv-1], 1:surf.naterm*2+2] \ surf.RHS[[1:surf.ndiv*2-3; 2*surf.ndiv-1]]
#         soln = surf.LHS[1:surf.ndiv*2-3, 1:surf.naterm*2+1] \ (surf.RHS[1:surf.ndiv*2-3] + RHSvort[:])

#         #Assign the solution
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i]
#             surf.bterm[i] = soln[i+surf.naterm]
#         end
#         tevstr = soln[2*surf.naterm+1]*surf.uref*surf.c
#         push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))
#         push!(curfield.lev, u_vort)

#         #Calculate adot
#         update_atermdot(surf, dt)

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:3
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Update induced velocities to include effect of last shed vortex
#         update_indbound(surf, curfield)

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         #Force calculation
#         cnc, cnnc, cn, cs, cl, cd, int_wax, int_c, int_t = calc_forces(surf, int_wax, int_c, int_t, dt)
#         #println(phi_u)
#         qu, ql, phi_u, phi_l, cpu, cpl = calc_edgeVel_cp(surf, [curfield.u[1]; curfield.w[1]], phi_u, phi_l, dt)
#         #println(phi_l)
#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield, qu, ql, cpu, cpl)
#             end
#         end

#         #LE velocity and stagnation point location
#         #vle = (surf.kinem.u + curfield.u[1])*sin(surf.kinem.alpha) + (curfield.w[1] - surf.kinem.hdot)*cos(surf.kinem.alpha) - surf.kinem.alphadot*surf.pvt*surf.c + sum(surf.aterm) + surf.wind_u[1]  


#         vle = qu[1]

#         if vle > 0.
#             qspl = Spline1D(surf.x, ql)
#             stag = try
#                 roots(qspl, maxn=1)[1]
#             catch
#                 0.
#             end
#         else
#             qspl = Spline1D(surf.x, qu)
#             stag = try
#                 roots(qspl, maxn=1)[1]
#             catch
#                 0.
#             end
#         end

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
#                         cl, cd, cnc, cnnc, cn, cs, stag])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "A0 \t", "Cl \t", "Cd \t", "Cm \n"])
#     writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end

# function ldvm(surf::TwoDSurfThick, curfield::TwoDFlowField, nsteps::Int64 = 500,
#                 dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000.,
#                 delvort = delNone(); maxwrite = 100, nround=6)

#     # If a restart directory is provided, read in the simulation data
#     if startflag == 0
#         mat = zeros(0, 11)
#         t = 0.
#     elseif startflag == 1
#         dirvec = readdir()
#         dirresults = map(x->(v = tryparse(Float64,x); isnull(v) ? 0.0 : get(v)),dirvec)
#         latestTime = maximum(dirresults)
#         mat = readdlm("resultsSummary")
#         t = mat[end,1]
#     else
#         throw("invalid start flag, should be 0 or 1")
#     end
#     mat = mat'

#     dt = dtstar*surf.c/surf.uref

#     # if writeflag is on, determine the timesteps to write at
#     if writeflag == 1
#         writeArray = Int64[]
#         tTot = nsteps*dt
#         for i = 1:maxwrite
#             tcur = writeInterval*real(i)
#             if t > tTot
#                 break
#             else
#                 push!(writeArray, Int(round(tcur/dt)))
#             end
#         end
#     end

#     vcore = 0.02*surf.c

#     int_wax = zeros(surf.ndiv)
#     int_c = zeros(surf.ndiv)
#     int_t = zeros(surf.ndiv)

#     for istep = 1:nsteps

#         #Udpate current time
#         t = t + dt

#         #Update kinematic parameters
#         update_kinem(surf, t)

#         #Update flow field parameters if any
#         update_externalvel(curfield, t)

#         #Update bound vortex positions
#         update_boundpos(surf, dt)

#         #Update incduced velocities on airfoil
#         update_indbound(surf, curfield)

#         #Set up the matrix problem
#         surf, xloc_tev, zloc_tev = update_thickLHS(surf, curfield, dt, vcore)

#         #Construct RHS vector
#         update_thickRHS(surf, curfield)

#         #Now solve the matrix problem
#         soln = surf.LHS[1:surf.ndiv*2-3, 1:surf.naterm*2+2] \ surf.RHS[1:surf.ndiv*2-3]

#         #Assign the solution
#         surf.a0[1] = soln[1]
#         for i = 1:surf.naterm
#             surf.aterm[i] = soln[i+1]
#             surf.bterm[i] = soln[i+surf.naterm+1]
#         end

#         #Calculate adot
#         surf.a0dot[1] = (surf.a0[1] - surf.a0prev[1])/dt
#         for ia = 1:surf.naterm
#             surf.adot[ia] = (surf.aterm[ia]-surf.aprev[ia])/dt
#         end

#         #Check if LEV shedding is true
#         lesp = sqrt(2. /surf.rho)*surf.a0[1]

#         if abs(lesp) > surf.lespcrit[1]

#             qu, ql = UNSflow.calc_edgeVel(surf, [0.; 0.])
#             qshed = maximum(qu)
#             levstr = dt*surf.uref^2*qshed^2/15

#             if surf.levflag[1] == 0
#                 le_vel_x = sqrt(2. /surf.rho)*surf.uref*surf.a0[1]*sin(surf.kinem.alpha)
#                 le_vel_z = sqrt(2. /surf.rho)*surf.uref*surf.a0[1]*cos(surf.kinem.alpha)
#                 xloc_lev = surf.bnd_x_u[1] + 0.5*le_vel_x*dt
#                 zloc_lev = surf.bnd_z_u[1] + 0.5*le_vel_z*dt
#             else
#                 xloc_lev = surf.bnd_x_u[1]+(1. /3.)*(curfield.lev[end].x - surf.bnd_x_u[1])
#                 zloc_lev = surf.bnd_z_u[1]+(1. /3.)*(curfield.lev[end].z - surf.bnd_z_u[1])
#             end

#             push!(curfield.lev, TwoDVort(xloc_lev, zloc_lev, levstr, vcore, 0., 0.))

#             #Update incduced velocities on airfoil
#             update_indbound(surf, curfield)

#             #Set up the matrix problem
#             surf, xloc_tev, zloc_tev = update_thickLHS(surf, curfield, dt, vcore)

#             #Construct RHS vector
#             update_thickRHS(surf, curfield)

#             #Now solve the matrix problem
#             soln = surf.LHS[1:surf.ndiv*2-3, 1:surf.naterm*2+2] \ surf.RHS[1:surf.ndiv*2-3]

#             #Assign the solution
#             surf.a0[1] = soln[1]
#             for i = 1:surf.naterm
#                 surf.aterm[i] = soln[i+1]
#                 surf.bterm[i] = soln[i+surf.naterm+1]
#             end

#             tevstr = soln[2*surf.naterm+2]*surf.uref*surf.c
#             push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))

#             surf.levflag[1] = 1
#         else
#             tevstr = soln[2*surf.naterm+2]*surf.uref*surf.c
#             push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, tevstr, vcore, 0., 0.))
#             surf.levflag[1] = 0
#         end

#         #Set previous values of aterm to be used for derivatives in next time step
#         surf.a0prev[1] = surf.a0[1]
#         for ia = 1:surf.naterm
#             surf.aprev[ia] = surf.aterm[ia]
#         end

#         #Update induced velocities to include effect of last shed vortex
#         update_indbound(surf, curfield)

#         #Calculate bound vortex strengths
#         update_bv_src(surf)

#         #Wake rollup
#         wakeroll(surf, curfield, dt)

#         #Force calculation
#         cnc, cnnc, cn, cs, cl, cd, int_wax, int_c, int_t = calc_forces(surf, int_wax, int_c, int_t, dt)

#         # write flow details if required
#         if writeflag == 1
#             if istep in writeArray
#                 dirname = "$(round(t,sigdigits=nround))"
#                 writeStamp(dirname, t, surf, curfield)
#             end
#         end

#         mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, surf.a0[1],
#                         cl, cd, cnc, cnnc, cn, cs])

#     end

#     mat = mat'

#     f = open("resultsSummary", "w")
#     Serialization.serialize(f, ["#time \t", "alpha (rad) \t", "h/c \t", "u/uref \t", "A0 \t", "Cl \t", "Cd \t", "Cm \n"])
#     DelimitedFiles.writedlm(f, mat)
#     close(f)

#     mat, surf, curfield
# end
