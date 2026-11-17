// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ViveTuPlaza - Fase 3a: crear actividades e inscribirse
/// @notice Roles + creación de actividades + inscripción con plazas limitadas
///         y lista de espera por orden de llegada.
contract ViveTuPlaza {
    // ------------------------------------------------------------------
    // Tipos
    // ------------------------------------------------------------------

    /// Estados por los que pasa una actividad.
    enum EstadoActividad { Abierta, Cancelada, Finalizada }

    /// Estados de la inscripción de una persona en una actividad.
    enum EstadoInscripcion {
        Ninguna,     // 0: nunca se ha inscrito
        Inscrito,    // 1: tiene plaza confirmada
        EnEspera,    // 2: está en la lista de espera
        Cancelada,   // 3: canceló su plaza o su puesto en espera
        Asistio,     // 4: asistencia confirmada
        NoAsistio,   // 5: no se presentó
        NoAdmitido,  // 6: seguía en espera cuando la actividad terminó
        Anulada      // 7: el organizador canceló la actividad
    }

    struct Actividad {
        uint256 id;
        address organizador;
        bytes32 hashFicha;          // huella de la ficha guardada fuera de la cadena
        uint64  fechaInicio;        // marcas de tiempo Unix (segundos desde 1970)
        uint64  limiteInscripcion;
        uint64  limiteCancelacion;
        uint32  plazasTotales;
        uint32  plazasOcupadas;
        uint32  maxListaEspera;
        uint32  enEspera;           // personas en espera en este momento
        EstadoActividad estado;
    }

    struct Participante {
        bool    registrado;
        bytes32 hashIdentidad;      // seudónimo: nunca el DNI ni el nombre
    }

    // ------------------------------------------------------------------
    // Almacenamiento
    // ------------------------------------------------------------------

    address public administrador;   // Ayuntamiento

    mapping(address => bool)         public organizadores;   // entidades acreditadas
    mapping(address => Participante) public participantes;   // personas dadas de alta

    uint256 public numActividades;                           // la primera tendrá id 1
    mapping(uint256 => Actividad) public actividades;

    /// actividadId => participante => estado de su inscripción
    mapping(uint256 => mapping(address => EstadoInscripcion)) public inscripciones;

    /// Lista de espera FIFO de cada actividad: cola + índice de la cabeza.
    mapping(uint256 => address[]) private colaEspera;
    mapping(uint256 => uint256)   private cabezaCola;
    /// Posición (+1) de cada persona en la cola; 0 = no está en ella.
    mapping(uint256 => mapping(address => uint256)) private posicionCola;

    /// Todas las personas que han pasado por cada actividad
    /// (se recorre al cancelar o finalizar la actividad).
    mapping(uint256 => address[]) private historico;

    // ------------------------------------------------------------------
    // Eventos (quedan registrados en la cadena y se ven en Remix)
    // ------------------------------------------------------------------

    event OrganizadorAcreditado(address indexed organizador);
    event OrganizadorRevocado(address indexed organizador);
    event ParticipanteRegistrado(address indexed participante, bytes32 hashIdentidad);
    event ParticipanteDadoDeBaja(address indexed participante);
    event AdministracionTransferida(address indexed anterior, address indexed nuevo);
    event ActividadCreada(uint256 indexed actividadId, address indexed organizador, uint32 plazas, uint64 fechaInicio);
    event Inscrito(uint256 indexed actividadId, address indexed participante);
    event AnadidoAListaEspera(uint256 indexed actividadId, address indexed participante, uint256 posicion);
    event InscripcionCancelada(uint256 indexed actividadId, address indexed participante, bool tardia);
    event PromocionadoDesdeEspera(uint256 indexed actividadId, address indexed participante);

    // ------------------------------------------------------------------
    // Modificadores (comprobaciones reutilizables antes de ejecutar una función)
    // ------------------------------------------------------------------

    modifier soloAdministrador() {
        require(msg.sender == administrador, "Solo el administrador");
        _;
    }

    modifier soloOrganizador() {
        require(organizadores[msg.sender], "No es un organizador acreditado");
        _;
    }

    modifier soloParticipante() {
        require(participantes[msg.sender].registrado, "Participante no registrado");
        _;
    }

    /// Los mappings devuelven valores por defecto para ids que no existen
    /// (una actividad inexistente aparecería como "Abierta"), así que se comprueba.
    modifier actividadExiste(uint256 actividadId) {
        require(actividadId > 0 && actividadId <= numActividades, "La actividad no existe");
        _;
    }

    // ------------------------------------------------------------------

    constructor() {
        administrador = msg.sender;
    }

    // ------------------------------------------------------------------
    // Funciones del ADMINISTRADOR
    // ------------------------------------------------------------------

    function acreditarOrganizador(address organizador) external soloAdministrador {
        require(organizador != address(0), "Direccion no valida");
        require(!organizadores[organizador], "Ya esta acreditado");
        organizadores[organizador] = true;
        emit OrganizadorAcreditado(organizador);
    }

    function revocarOrganizador(address organizador) external soloAdministrador {
        require(organizadores[organizador], "No esta acreditado");
        organizadores[organizador] = false;
        emit OrganizadorRevocado(organizador);
    }

    /// @notice Alta de una persona mayor. Fuera de la cadena (el "oráculo" del padrón,
    ///         simulado aquí por el administrador) se ha comprobado que cumple los requisitos.
    function registrarParticipante(address participante, bytes32 hashIdentidad) external soloAdministrador {
        require(participante != address(0), "Direccion no valida");
        require(!participantes[participante].registrado, "Ya registrado");
        participantes[participante] = Participante({registrado: true, hashIdentidad: hashIdentidad});
        emit ParticipanteRegistrado(participante, hashIdentidad);
    }

    function darDeBajaParticipante(address participante) external soloAdministrador {
        require(participantes[participante].registrado, "No registrado");
        participantes[participante].registrado = false;
        emit ParticipanteDadoDeBaja(participante);
    }

    function transferirAdministracion(address nuevo) external soloAdministrador {
        require(nuevo != address(0), "Direccion no valida");
        emit AdministracionTransferida(administrador, nuevo);
        administrador = nuevo;
    }

    // ------------------------------------------------------------------
    // Funciones del ORGANIZADOR
    // ------------------------------------------------------------------

    function crearActividad(
        bytes32 hashFicha,
        uint64  fechaInicio,
        uint64  limiteInscripcion,
        uint64  limiteCancelacion,
        uint32  plazasTotales,
        uint32  maxListaEspera
    ) external soloOrganizador returns (uint256 actividadId) {
        require(plazasTotales > 0, "Debe haber al menos una plaza");
        require(fechaInicio > block.timestamp, "La fecha de inicio debe ser futura");
        require(limiteInscripcion <= fechaInicio, "Limite de inscripcion posterior al inicio");
        require(limiteCancelacion <= fechaInicio, "Limite de cancelacion posterior al inicio");

        actividadId = ++numActividades;          // la primera actividad tiene id 1
        actividades[actividadId] = Actividad({
            id: actividadId,
            organizador: msg.sender,
            hashFicha: hashFicha,
            fechaInicio: fechaInicio,
            limiteInscripcion: limiteInscripcion,
            limiteCancelacion: limiteCancelacion,
            plazasTotales: plazasTotales,
            plazasOcupadas: 0,
            maxListaEspera: maxListaEspera,
            enEspera: 0,
            estado: EstadoActividad.Abierta
        });
        emit ActividadCreada(actividadId, msg.sender, plazasTotales, fechaInicio);
    }

    // ------------------------------------------------------------------
    // Funciones del PARTICIPANTE
    // ------------------------------------------------------------------

    function inscribirse(uint256 actividadId) external soloParticipante actividadExiste(actividadId) {
        Actividad storage a = actividades[actividadId];   // "storage": se modifica el dato guardado
        require(a.estado == EstadoActividad.Abierta, "La actividad no esta abierta");
        require(block.timestamp <= a.limiteInscripcion, "Plazo de inscripcion cerrado");

        EstadoInscripcion actual = inscripciones[actividadId][msg.sender];
        require(
            actual == EstadoInscripcion.Ninguna || actual == EstadoInscripcion.Cancelada,
            "Ya tiene una inscripcion en esta actividad"
        );
        if (actual == EstadoInscripcion.Ninguna) {
            historico[actividadId].push(msg.sender);     // primera vez que pasa por la actividad
        }

        if (a.plazasOcupadas < a.plazasTotales) {
            // Queda plaza: inscripción directa
            a.plazasOcupadas++;
            inscripciones[actividadId][msg.sender] = EstadoInscripcion.Inscrito;
            emit Inscrito(actividadId, msg.sender);
        } else {
            // No quedan plazas: al final de la lista de espera, si cabe
            require(a.enEspera < a.maxListaEspera, "Lista de espera completa");
            colaEspera[actividadId].push(msg.sender);
            posicionCola[actividadId][msg.sender] = colaEspera[actividadId].length; // índice + 1
            a.enEspera++;
            inscripciones[actividadId][msg.sender] = EstadoInscripcion.EnEspera;
            emit AnadidoAListaEspera(actividadId, msg.sender, a.enEspera);
        }
    }

    /// @notice Cancela la plaza o el puesto en la lista de espera de quien llama.
    ///         Si libera una plaza dentro del plazo de inscripción, la ocupa
    ///         automáticamente la primera persona válida de la lista de espera.
    function cancelarInscripcion(uint256 actividadId) external actividadExiste(actividadId) {
        Actividad storage a = actividades[actividadId];
        require(a.estado == EstadoActividad.Abierta, "La actividad no esta abierta");
        require(block.timestamp < a.fechaInicio, "La actividad ya ha empezado");

        EstadoInscripcion actual = inscripciones[actividadId][msg.sender];
        require(
            actual == EstadoInscripcion.Inscrito || actual == EstadoInscripcion.EnEspera,
            "No tiene inscripcion activa"
        );

        inscripciones[actividadId][msg.sender] = EstadoInscripcion.Cancelada;
        bool tardia = false;

        if (actual == EstadoInscripcion.EnEspera) {
            // Sale de la cola: no se borra nada, su entrada simplemente deja de ser válida
            posicionCola[actividadId][msg.sender] = 0;
            a.enEspera--;
        } else {
            // Tenía plaza: se libera y se ofrece al siguiente de la lista de espera
            a.plazasOcupadas--;
            tardia = block.timestamp > a.limiteCancelacion;   // en la Fase 4 contará como incidencia
            _promocionarSiguiente(actividadId);
        }
        emit InscripcionCancelada(actividadId, msg.sender, tardia);
    }

    // ------------------------------------------------------------------
    // Consultas
    // ------------------------------------------------------------------

    function plazasLibres(uint256 actividadId) external view actividadExiste(actividadId) returns (uint32) {
        Actividad storage a = actividades[actividadId];
        return a.plazasTotales - a.plazasOcupadas;
    }

    /// @return posición en la lista de espera (1 = la siguiente en entrar) o 0 si no está en espera
    function posicionEnEspera(uint256 actividadId, address participante) external view returns (uint256) {
        if (inscripciones[actividadId][participante] != EstadoInscripcion.EnEspera) return 0;
        uint256 miIndice = posicionCola[actividadId][participante] - 1;
        address[] storage cola = colaEspera[actividadId];
        uint256 posicion = 0;
        for (uint256 i = cabezaCola[actividadId]; i <= miIndice; i++) {
            if (_entradaValida(actividadId, i, cola[i])) posicion++;
        }
        return posicion;
    }

    function ahora() external view returns (uint256) {
        return block.timestamp;
    }

    // ------------------------------------------------------------------
    // Lógica interna
    // ------------------------------------------------------------------

    /// Recorre la cola desde la cabeza saltando entradas no válidas (personas que
    /// cancelaron o que se reinscribieron) y da la plaza a la primera válida.
    function _promocionarSiguiente(uint256 actividadId) private {
        Actividad storage a = actividades[actividadId];
        if (block.timestamp > a.limiteInscripcion) return;   // fuera de plazo no se reasignan plazas

        address[] storage cola = colaEspera[actividadId];
        uint256 i = cabezaCola[actividadId];
        while (i < cola.length) {
            address candidato = cola[i];
            i++;
            if (_entradaValida(actividadId, i - 1, candidato)) {
                cabezaCola[actividadId] = i;                  // la cabeza avanza tras el promocionado
                posicionCola[actividadId][candidato] = 0;
                inscripciones[actividadId][candidato] = EstadoInscripcion.Inscrito;
                a.plazasOcupadas++;
                a.enEspera--;
                emit PromocionadoDesdeEspera(actividadId, candidato);
                return;
            }
        }
        cabezaCola[actividadId] = i;                          // cola agotada: no había nadie válido
    }

    /// Una entrada de la cola es válida si esa persona sigue en espera y esa
    /// entrada es la suya actual (si canceló y se reinscribió, la antigua no cuenta).
    function _entradaValida(uint256 actividadId, uint256 indice, address p) private view returns (bool) {
        return inscripciones[actividadId][p] == EstadoInscripcion.EnEspera
            && posicionCola[actividadId][p] == indice + 1;
    }
}