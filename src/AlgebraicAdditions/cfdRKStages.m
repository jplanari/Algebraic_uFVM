function cfdRKStages

global Region;

op = Region.operators;

RK = Region.foamDictionary.fvSchemes.ddtSchemes.RK;

if isfield(Region.foamDictionary.fvSolution.solvers, 'pFinal')
    sol = Region.foamDictionary.fvSolution.solvers.pFinal;
else
    sol = Region.foamDictionary.fvSolution.solvers.p;
end

theNumberOfFaces = cfdGetNumberOfFaces;

deltaT = cfdGetDeltaT;

nu = Region.foamDictionary.transportProperties.nu.propertyValue;

p = cfdGetField('p');
U = cfdGetField('U');
Uf = cfdGetField('Uf');

% Reset for RK scheme
UOld = U;
pOld = p;
dUs = zeros(size(U, 1), RK.nStages);

for iStage = 1:RK.nStages + 1
    % Stage increment of U
    % Is there a better way to include a pressure prediction?
    % Perhaps using updated intermediate values of pressure?
    U = UOld + dUs*RK.aTab(iStage, :)'; % - sum(RK.aTab(iStage,:)) * deltaT * pnPredCoef * op.Gc * pOld (To do - 3)
    U = cfdBCUpdate(U, 'U');

    if ~((iStage == 1) && (RK.aTab(1, 1) == 0))     % Skip stage if first & explicit
        divU = cfdGetInternalField(op.Mc * U, 'vsf');
        source = divU + deltaT*op.Pois.addSource;

        % Intermediate p used for predictor, is it optimal?
        dtp = deltaT * cfdGetInternalField(p, 'vsf');

        % Include preconditioner (To do - 4)
        [dtp, relres, iterpcg, resvec] = cfdCheckpcg(-op.Pois.Lap, -source, sol.tolerance, sol.maxIter, speye(size(dtp, 1)), speye(size(dtp, 1)), dtp);

        p = cfdSetInternalField(p, dtp/deltaT, 'vsf');
        p = cfdBCUpdate(p, 'p');

        % Velocity update
        U = U - deltaT * op.Gc * p;
        U = cfdBCUpdate(U, 'U');

        if strcmp(Region.foamDictionary.fvSchemes.laplacianSchemes.default, 'compact')
            Uf = op.GamCS*U + deltaT * (op.GamCS*op.GamSC - speye(theNumberOfFaces)) * op.G * p;
        else
            Uf = op.GamCS*U;
        end

        % Experiment with mixed Laplacian
        % Us = op.GamCS*U+op.LMix*(op.GamCS*op.GamSC - speye(geo.nf))*op.G * dtp; (To do - 5)
    end

    if iStage <= RK.nStages
        % Set convective
        Con = kron(eye(3), op.M*spdiags(Uf, 0, theNumberOfFaces, theNumberOfFaces)*op.PiCSM);

        % Set delta U for this stage
        dUs(:, iStage) = -deltaT * (op.Omega\((Con - nu * kron(eye(3), op.L))*U));
    end
end

% p = pnPredCoef*pOld + p; (To do - 3)

cfdSetField(p, 'p');
cfdSetField(U, 'U');
cfdSetField(Uf, 'Uf');